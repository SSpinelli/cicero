import Testing
@testable import CiceroKit

@MainActor
@Suite("DictationEngine error handling")
struct DictationEngineErrorTests {

    private func makeEngine(
        recorder: FakeRecorder = FakeRecorder(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        polisher: FakePolisher = FakePolisher(),
        inserter: FakeInserter = FakeInserter()
    ) -> DictationEngine {
        DictationEngine(recorder: recorder, transcriber: transcriber,
                        polisher: polisher, inserter: inserter,
                        contextProvider: FakeContextProvider())
    }

    @Test("falls back to the raw transcript when polishing fails")
    func polisherFailureInsertsRawText() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "raw words"),
            polisher: FakePolisher(error: .polishingFailed("modelo indisponível")),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value == ["raw words"])
        #expect(engine.state == .idle)
    }

    @Test("silent audio inserts nothing and returns to idle")
    func silentAudioInsertsNothing() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            recorder: FakeRecorder(buffer: AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value.isEmpty)
        #expect(engine.state == .idle)
    }

    @Test("a blank transcript inserts nothing")
    func blankTranscriptInsertsNothing() async {
        let inserter = FakeInserter()
        let engine = makeEngine(transcriber: FakeTranscriber(result: "   \n "), inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value.isEmpty)
        #expect(engine.state == .idle)
    }

    @Test("transcription failure surfaces a message and returns to a startable state")
    func transcriptionFailure() async {
        let engine = makeEngine(transcriber: FakeTranscriber(error: .transcriptionFailed("modelo ausente")))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.state == .failed(CiceroError.transcriptionFailed("modelo ausente").userMessage))
        await engine.startDictation()
        #expect(engine.state == .recording)
    }

    @Test("recording failure surfaces a message")
    func recordingFailure() async {
        let engine = makeEngine(recorder: FakeRecorder(startError: .recordingFailed("sem microfone")))
        await engine.startDictation()
        #expect(engine.state == .failed(CiceroError.recordingFailed("sem microfone").userMessage))
    }

    @Test("insertion failure keeps the transcript retrievable")
    func insertionFailureKeepsTranscript() async {
        let engine = makeEngine(
            polisher: FakePolisher(result: "Palavras polidas."),
            inserter: FakeInserter(error: .insertionBlockedBySecureInput))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.lastTranscript == "Palavras polidas.")
        #expect(engine.state == .failed(CiceroError.insertionBlockedBySecureInput.userMessage))
    }

    @Test("cancelling during recording inserts nothing")
    func cancelInsertsNothing() async {
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let engine = makeEngine(recorder: recorder, inserter: inserter)
        await engine.startDictation()
        await engine.cancelDictation()
        #expect(engine.state == .idle)
        #expect(recorder.cancelled.value)
        #expect(inserter.inserted.value.isEmpty)
    }
}
