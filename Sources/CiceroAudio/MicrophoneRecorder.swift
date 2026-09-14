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

    private var samples: [Float] = []

    /// Where the recorder is in its lifecycle, claimed *synchronously* by
    /// `start()`/`stop()`/`cancel()` before their first `await`. This actor is
    /// reentrant — any `await` is a point where another call can interleave —
    /// so a plain `Bool` set only after the (up to `engineTimeout`-long)
    /// engine setup would let a `stop()`/`cancel()` arriving during that
    /// window see a stale "not running" state. `DictationEngine` hit this
    /// exact defect class; here it's closed by making every phase transition
    /// an explicit, immediately-visible enum case instead of a flag flipped
    /// after the fact.
    private enum Phase {
        case idle
        case starting(Task<StartOutcome, Never>)
        case running(Session)
        case stopping(Task<Void, Never>)
    }

    /// State for one in-progress recording. Bundles the engine created for
    /// this attempt with the plumbing that carries its captured samples to
    /// `samples` in order (see `start()`'s doc comment on ordering, and on
    /// why `consumer` must not capture this actor strongly).
    private struct Session {
        let engine: AVAudioEngine
        let continuation: AsyncStream<[Float]>.Continuation
        let consumer: Task<Void, Never>
    }

    private enum StartOutcome: Sendable {
        case success
        case failure(CiceroError)
    }

    private var phase: Phase = .idle

    public init() {}

    /// Best-effort safety net for the case `stop()`/`cancel()` were never
    /// called at all — the owner (e.g. `DictationEngine`) was itself
    /// deallocated, or simply dropped this recorder, while it was
    /// `.running`. This is the "termination path that does not depend on the
    /// owner still being alive": it runs exactly when the owner stops being
    /// alive, by construction of `deinit`.
    ///
    /// It cannot use `Self.stopEngine`'s bounded-timeout dance (`deinit`
    /// can't be `async`), so this is a plain synchronous best-effort stop —
    /// acceptable here because this path only exists to catch misuse
    /// (`DictationEngine` always calls `cancel()` during its own teardown;
    /// see its type-level doc comment), not because it needs the same
    /// guarantees as the primary `start()`/`stop()`/`cancel()` paths.
    /// Reading `phase` synchronously here is safe: by the time an actor's
    /// `deinit` runs, no other code can be concurrently isolated to it.
    deinit {
        if case .running(let session) = phase {
            session.engine.inputNode.removeTap(onBus: 0)
            session.engine.stop()
            session.continuation.finish()
        }
    }

    /// Starts capturing from the default input device.
    ///
    /// A fresh `AVAudioEngine` is created for every call, held only for the
    /// duration of this attempt (never as a stored actor property). This
    /// matters because the actual setup runs on a background thread, raced
    /// against `engineTimeout`: `AVAudioEngine.inputNode` and `.start()` are
    /// synchronous calls into the CoreAudio HAL that can block indefinitely —
    /// Swift structured concurrency can request cancellation of a task, but
    /// cannot forcibly interrupt a blocking call already in flight, so racing
    /// on a separate thread is the only way to guarantee this method
    /// returns. If the timeout wins, that background work may still be
    /// running; if it later succeeds anyway, `startEngine` tears its tap and
    /// engine back down immediately, since the caller has already been told
    /// `start()` failed. Giving each attempt its own engine instance means
    /// that abandoned background work can only ever touch an engine nothing
    /// else references — never one a *later* `start()` call is using.
    ///
    /// Captured buffers are handed to `samples` through an `AsyncStream`
    /// rather than one unstructured `Task` per tap callback: Swift does not
    /// guarantee that unstructured tasks created in order A-then-B are
    /// scheduled onto the actor in that order, and reordered audio would
    /// silently produce a garbled transcript in Task 5. The tap callback
    /// (invoked serially, one buffer at a time, by CoreAudio) `yield`s
    /// synchronously into the stream; a single consumer task drains it in
    /// strict FIFO order onto `samples`. That consumer captures `self`
    /// *weakly* — see the doc comment on `Session.consumer` for why a strong
    /// capture there is a live-microphone leak, not just an ordinary cycle.
    ///
    /// Calling `start()` while a previous call is still in flight or still
    /// tearing down does not lie about the outcome: while `.starting`, this
    /// waits for and mirrors that attempt's real result instead of claiming
    /// immediate success for a recording that might still fail; while
    /// `.stopping`, this waits for the teardown to finish (it always settles
    /// to `.idle`) and then makes a genuine new attempt, instead of claiming
    /// success for a session that is guaranteed to end up not recording.
    public func start() async throws {
        switch phase {
        case .running:
            return
        case .starting(let task):
            switch await task.value {
            case .success:
                return
            case .failure(let error):
                throw error
            }
        case .stopping(let task):
            await task.value
            try await start()
            return
        case .idle:
            break
        }

        samples.removeAll(keepingCapacity: true)

        let sessionEngine = AVAudioEngine()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let appendSamples: @Sendable ([Float]) -> Void = { chunk in
            continuation.yield(chunk)
        }

        let task = Task<StartOutcome, Never> { [weak self] in
            let result = await Self.startEngine(sessionEngine, appendSamples: appendSamples)
            guard let self else {
                // The recorder was dropped while the engine was still coming
                // up. If the start actually succeeded, a tap is installed on a
                // running engine that nothing will ever stop: `deinit` cannot
                // help, because `phase` never reached `.running`, and the
                // engine is referenced only by this closure. Release it here,
                // through the engine instance this attempt already captured —
                // the same cleanup `startEngine` does when the timeout wins.
                if case .success = result {
                    sessionEngine.inputNode.removeTap(onBus: 0)
                    sessionEngine.stop()
                }
                continuation.finish()
                return .failure(.recordingFailed("gravador não existe mais"))
            }
            switch result {
            case .success:
                // `[weak self]` here, not the strong `self` this closure could
                // otherwise capture from the enclosing `guard let self` scope:
                // a strongly-captured `self` would be held by a `Task` that
                // never completes until `teardown()` finishes the stream, and
                // `self` (via `phase` → `Session.consumer`) would in turn hold
                // that `Task` — a cycle that survives for as long as nobody
                // calls `stop()`/`cancel()`. If the owner drops this recorder
                // mid-recording (e.g. quitting while `DictationEngine` is
                // `.recording`), that cycle would keep the actor, the engine
                // and the live input tap alive for the rest of the process —
                // a hot microphone nothing can ever release. With a weak
                // capture, dropping the last external reference lets the
                // actor deinit, and `deinit` below force-stops the engine.
                let consumer = Task { [weak self] in
                    for await chunk in stream {
                        await self?.append(chunk)
                    }
                }
                await self.setRunning(Session(engine: sessionEngine, continuation: continuation, consumer: consumer))
                return .success
            case .failure(let error):
                continuation.finish()
                await self.setIdle()
                return .failure(error)
            }
        }
        phase = .starting(task)

        switch await task.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    public func stop() async throws -> CiceroKit.AudioBuffer {
        await awaitPendingStart()
        guard case .running = phase else {
            throw CiceroError.recordingFailed("gravação não estava ativa")
        }
        await teardown()
        return CiceroKit.AudioBuffer(samples: samples, sampleRate: Self.targetSampleRate)
    }

    /// Tears down the current recording, if any, and discards captured
    /// samples.
    ///
    /// Must tolerate being called after a `start()` that threw. The engine
    /// (`DictationEngine`) calls `cancel()` unconditionally during teardown,
    /// including on the failure path where `start()` never reached
    /// `.running` — in that case, once any in-flight start has settled,
    /// `phase` is back to `.idle` and this is a no-op. A `start()` only
    /// reaches `.running` after the tap is installed and the audio engine
    /// has started successfully, and every earlier failure path leaves no
    /// tap or running engine behind, so there is never a partially-started
    /// engine for `cancel()` to clean up.
    public func cancel() async {
        await awaitPendingStart()
        guard case .running = phase else { return }
        await teardown()
        samples.removeAll(keepingCapacity: false)
    }

    /// If a `start()` is currently in flight, waits for it to settle into
    /// `.running` or back to `.idle` before returning. Without this, a
    /// `stop()`/`cancel()` arriving while `start()` is still awaiting the
    /// (up to `engineTimeout`-long) engine setup would read the stale
    /// pre-transition phase — e.g. `stop()` throwing "not active" for a
    /// recording that was about to become active.
    private func awaitPendingStart() async {
        if case .starting(let task) = phase {
            _ = await task.value
        }
    }

    private func setRunning(_ session: Session) {
        phase = .running(session)
    }

    private func setIdle() {
        phase = .idle
    }

    private func teardown() async {
        guard case .running(let session) = phase else {
            ciceroLog.notice("teardown: fase nao era .running, no-op")
            return
        }
        ciceroLog.notice("teardown: inicio")
        // Claim `.stopping` synchronously before the (possibly slow) engine
        // teardown so this phase is visible to anything consulting it while
        // we're mid-teardown, same reasoning as `.starting` above.
        let stoppingTask = Task {
            ciceroLog.notice("teardown: parando engine de audio")
            await Self.stopEngine(session.engine)
            ciceroLog.notice("teardown: engine parado")
            session.continuation.finish()
            ciceroLog.notice("teardown: stream finalizado, aguardando consumidora")
            // Wait for the consumer to drain every buffer already yielded
            // before this method returns, so `stop()` never reads `samples`
            // with trailing audio still in flight.
            await session.consumer.value
            ciceroLog.notice("teardown: consumidora drenou tudo")
        }
        phase = .stopping(stoppingTask)
        await stoppingTask.value
        ciceroLog.notice("teardown: concluido")
        phase = .idle
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
