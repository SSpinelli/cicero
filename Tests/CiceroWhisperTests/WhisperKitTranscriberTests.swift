import AVFoundation
import Foundation
import Testing
import CiceroKit
@testable import CiceroWhisper

extension Tag {
    @Tag static var requiresModel: Tag
}

/// Renders speech with the built-in `say` command and loads it as 16 kHz mono
/// float samples, so the suite needs no committed audio fixture.
private func spokenAudio(_ text: String, voice: String? = nil) throws -> CiceroKit.AudioBuffer {
    let url = URL.temporaryDirectory.appending(path: "cicero-fixture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    var arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000"]
    if let voice { arguments.append(contentsOf: ["-v", voice]) }
    arguments.append(text)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/say")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CiceroError.transcriptionFailed("`say` falhou ao gerar o fixture")
    }

    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(file.length)),
          let channel = buffer.floatChannelData?[0] else {
        throw CiceroError.transcriptionFailed("não foi possível ler o fixture")
    }
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    return CiceroKit.AudioBuffer(samples: samples, sampleRate: file.processingFormat.sampleRate)
}

// `.serialized`: each test downloads the model independently via `prepare()`.
// Swift Testing runs a suite's tests concurrently by default, and two
// `WhisperKitTranscriber()` instances downloading the same ~1.5 GB model into
// the same shared Hugging Face cache directory at once race on renaming the
// same temporary file — reproduced as a genuine failure (one test's download
// clobbered the other's in-progress file) before this was added.
@Suite("WhisperKitTranscriber", .serialized)
struct WhisperKitTranscriberTests {

    @Test("transcribes spoken English", .tags(.requiresModel), .timeLimit(.minutes(10)))
    func transcribesEnglish() async throws {
        let transcriber = WhisperKitTranscriber()
        try await transcriber.prepare()
        let text = try await transcriber.transcribe(try spokenAudio("The quick brown fox jumps over the lazy dog."))
        #expect(text.lowercased().contains("brown fox"))
    }

    @Test("transcribes spoken Portuguese", .tags(.requiresModel), .timeLimit(.minutes(10)))
    func transcribesPortuguese() async throws {
        let transcriber = WhisperKitTranscriber()
        try await transcriber.prepare()
        let text = try await transcriber.transcribe(try spokenAudio("O rato roeu a roupa do rei.", voice: "Luciana"))
        #expect(text.lowercased().contains("rato"))
    }

    @Test("transcribing before prepare throws", .tags(.requiresModel))
    func transcribeBeforePrepareThrows() async {
        let transcriber = WhisperKitTranscriber()
        await #expect(throws: CiceroError.self) {
            _ = try await transcriber.transcribe(CiceroKit.AudioBuffer(samples: Array(repeating: 0.2, count: 16_000), sampleRate: 16_000))
        }
    }
}
