@preconcurrency import AVFoundation
import CiceroKit
import Foundation

/// Captures the default input device and hands back 16 kHz mono float audio,
/// the format WhisperKit expects.
///
/// An actor because `AVAudioEngine` and the accumulating sample array are
/// mutable state touched from the audio tap's background thread.
public actor MicrophoneRecorder: AudioRecorder {

    private static let targetSampleRate: Double = 16_000

    /// Bound on how long the engine is given to come up or tear down. See the
    /// doc comments on `start()` and `teardown()` for why this exists:
    /// `AVAudioEngine`'s calls into the CoreAudio HAL are synchronous and,
    /// while normally fast, have been observed to block indefinitely (e.g. a
    /// misbehaving audio device). `DictationEngine` holds a gate across the
    /// whole span of `start()`/`cancel()`, so an unbounded wait here would
    /// permanently wedge dictation for the rest of the app's lifetime.
    private static let engineTimeout: TimeInterval = 5

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRunning = false

    public init() {}

    /// Starts capturing from the default input device.
    ///
    /// The actual `AVAudioEngine` setup runs on a background thread, raced
    /// against `engineTimeout`, because `AVAudioEngine.inputNode` and
    /// `.start()` are synchronous calls into the CoreAudio HAL that can block
    /// indefinitely — Swift structured concurrency can request cancellation
    /// of a task, but cannot forcibly interrupt a blocking call already in
    /// flight, so racing on a separate thread is the only way to guarantee
    /// this method returns. If the timeout wins, the setup work may still be
    /// running in the background; if it later succeeds anyway, the tap and
    /// engine are torn back down immediately since the caller has already
    /// been told `start()` failed.
    public func start() async throws {
        guard !isRunning else { return }
        samples.removeAll(keepingCapacity: true)

        let engine = self.engine
        let appendSamples: @Sendable ([Float]) -> Void = { [weak self] newSamples in
            Task { await self?.append(newSamples) }
        }

        switch await Self.startEngine(engine, appendSamples: appendSamples) {
        case .success:
            isRunning = true
        case .failure(let error):
            throw error
        }
    }

    public func stop() async throws -> CiceroKit.AudioBuffer {
        guard isRunning else {
            throw CiceroError.recordingFailed("gravação não estava ativa")
        }
        await teardown()
        return CiceroKit.AudioBuffer(samples: samples, sampleRate: Self.targetSampleRate)
    }

    /// Tears down the engine and discards any captured samples.
    ///
    /// Must tolerate being called after a `start()` that threw. The engine
    /// (`DictationEngine`) calls `cancel()` unconditionally during teardown,
    /// including on the failure path where `start()` never reached
    /// `isRunning = true` — in that case this is a no-op. `start()` only sets
    /// `isRunning = true` after the tap is installed and the audio engine has
    /// started successfully, and every earlier failure path leaves no tap or
    /// running engine behind, so there is never a partially-started state for
    /// `cancel()` to clean up.
    public func cancel() async {
        guard isRunning else { return }
        await teardown()
        samples.removeAll(keepingCapacity: false)
    }

    private func teardown() async {
        // Flip the flag before the (possibly slow) engine teardown so a
        // concurrent `start()`/`stop()` never observes a half-torn-down engine.
        isRunning = false
        await Self.stopEngine(engine)
    }

    private func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    // MARK: - Bounded AVAudioEngine access

    private nonisolated static func startEngine(
        _ engine: AVAudioEngine,
        appendSamples: @escaping @Sendable ([Float]) -> Void
    ) async -> Result<Void, CiceroError> {
        let resumeGuard = ResumeGuard()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performStart(engine, appendSamples: appendSamples)
                if resumeGuard.markFirst() {
                    continuation.resume(returning: result)
                } else if case .success = result {
                    // The timeout already answered `start()` with failure.
                    // Don't leave a live engine capturing audio behind the
                    // caller's back.
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + engineTimeout) {
                if resumeGuard.markFirst() {
                    continuation.resume(returning: .failure(
                        .recordingFailed("tempo esgotado ao acessar o microfone")))
                }
            }
        }
    }

    private nonisolated static func stopEngine(_ engine: AVAudioEngine) async {
        let resumeGuard = ResumeGuard()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                if resumeGuard.markFirst() {
                    continuation.resume()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + engineTimeout) {
                if resumeGuard.markFirst() {
                    continuation.resume()
                }
            }
        }
    }

    private nonisolated static func performStart(
        _ engine: AVAudioEngine,
        appendSamples: @escaping @Sendable ([Float]) -> Void
    ) -> Result<Void, CiceroError> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            return .failure(.recordingFailed("nenhum dispositivo de entrada disponível"))
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return .failure(.recordingFailed("não foi possível converter o formato de áudio"))
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = convert(buffer, using: converter, to: targetFormat) else { return }
            appendSamples(converted)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .failure(.recordingFailed(error.localizedDescription))
        }
        return .success(())
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // `AVAudioConverterInputBlock` is a plain (unaudited) closure type, so the
        // compiler must assume it could run concurrently — a captured `var` would
        // be a data race under strict concurrency checking even though, for this
        // synchronous single-buffer conversion, it is only ever invoked serially
        // on the calling thread. `InputState` boxes the flag behind an
        // `@unchecked Sendable` reference type to make that guarantee explicit.
        let state = InputState()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if state.supplied {
                status.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Tracks whether the single input buffer has already been handed to the
    /// converter. In practice `AVAudioConverterInputBlock` is invoked
    /// synchronously and serially by `convert(to:error:withInputFromBlock:)`,
    /// never concurrently, so `@unchecked Sendable` is safe here.
    private final class InputState: @unchecked Sendable {
        var supplied = false
    }

    /// Ensures a `CheckedContinuation` raced between two callers (the real
    /// work and the timeout) is resumed exactly once. Whichever side calls
    /// `markFirst()` first wins and gets `true`; the loser gets `false`.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func markFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }
}
