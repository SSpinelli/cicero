import Testing
import CiceroKit
@testable import CiceroAudio

extension Tag {
    @Tag static var requiresMicrophone: Tag
}

@Suite("MicrophoneRecorder")
struct MicrophoneRecorderTests {

    @Test("records at 16 kHz mono", .tags(.requiresMicrophone))
    func recordsAtWhisperFormat() async throws {
        let recorder = MicrophoneRecorder()
        try await recorder.start()
        try await Task.sleep(for: .seconds(1))
        let buffer = try await recorder.stop()

        #expect(buffer.sampleRate == 16_000)
        #expect(buffer.duration > 0.5)
        #expect(buffer.duration < 2.0)
        // Depends on the room not being perfectly silent during the 1s capture
        // above. If this fails in an otherwise-working environment, check
        // whether the machine was actually silent — it isn't proof of a bug.
        #expect(!buffer.isSilent(), "captured buffer is silent — either the room was silent during the test, or audio capture is producing empty/garbage samples")
    }

    @Test("stopping without starting throws", .tags(.requiresMicrophone))
    func stopWithoutStartThrows() async {
        let recorder = MicrophoneRecorder()
        await #expect(throws: CiceroError.self) {
            _ = try await recorder.stop()
        }
    }
}
