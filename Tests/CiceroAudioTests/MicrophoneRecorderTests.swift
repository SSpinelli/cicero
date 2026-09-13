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
    }

    @Test("stopping without starting throws", .tags(.requiresMicrophone))
    func stopWithoutStartThrows() async {
        let recorder = MicrophoneRecorder()
        await #expect(throws: CiceroError.self) {
            _ = try await recorder.stop()
        }
    }
}
