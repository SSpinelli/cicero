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

    @Test("dropping the recorder mid-recording still deallocates it", .tags(.requiresMicrophone))
    func droppingWithoutStopOrCancelDeallocates() async throws {
        weak var weakRecorder: MicrophoneRecorder?

        // Reaches `.running` (a real successful `start()`) and then drops the
        // only strong reference without ever calling `stop()`/`cancel()` —
        // simulating the owner (e.g. `DictationEngine`) being torn down
        // mid-recording. Before the fix, the consumer task's strong capture
        // of `self` formed a cycle (actor -> phase -> Session -> consumer
        // Task -> actor) that nothing but `teardown()` ever broke, so the
        // recorder — and the live microphone tap — would leak for the life
        // of the process.
        try await {
            let recorder = MicrophoneRecorder()
            weakRecorder = recorder
            try await recorder.start()
        }()

        // Actor deallocation happens synchronously with the last strong
        // reference going away, but poll briefly rather than asserting
        // immediately, in case of any scheduling slack.
        var attempts = 0
        while weakRecorder != nil && attempts < 20 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }

        #expect(weakRecorder == nil, "recorder did not deallocate after its only strong reference was dropped without stop()/cancel() — the consumer task is likely still retaining it (the actor -> phase -> Session -> consumer Task cycle regressed)")
    }
}
