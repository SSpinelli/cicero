import Testing
@testable import CiceroKit

@MainActor
@Suite("DictationEngine happy path")
struct DictationEngineHappyPathTests {

    private func makeEngine(
        recorder: FakeRecorder = FakeRecorder(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        polisher: FakePolisher = FakePolisher(),
        inserter: FakeInserter = FakeInserter(),
        contextProvider: FakeContextProvider = FakeContextProvider()
    ) -> DictationEngine {
        DictationEngine(recorder: recorder, transcriber: transcriber,
                        polisher: polisher, inserter: inserter,
                        contextProvider: contextProvider)
    }

    @Test("starts idle")
    func startsIdle() {
        #expect(makeEngine().state == .idle)
    }

    @Test("moves to recording when dictation starts")
    func movesToRecording() async {
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        await engine.startDictation()
        #expect(engine.state == .recording)
        #expect(recorder.started.value)
    }

    @Test("returns to idle after a full dictation")
    func returnsToIdle() async {
        let engine = makeEngine()
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.state == .idle)
    }

    @Test("inserts the polished text, not the raw transcript")
    func insertsPolishedText() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "raw words"),
            polisher: FakePolisher(result: "Polished words."),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value == ["Polished words."])
    }

    @Test("passes the frontmost app context to the polisher")
    func passesContext() async {
        let polisher = FakePolisher()
        let engine = makeEngine(
            polisher: polisher,
            contextProvider: FakeContextProvider(
                context: DictationContext(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(polisher.receivedContext.value.appName == "Slack")
    }

    @Test("remembers the last transcript")
    func remembersLastTranscript() async {
        let engine = makeEngine(polisher: FakePolisher(result: "Polished words."))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.lastTranscript == "Polished words.")
    }

    @Test("ignores a second start while already recording")
    func ignoresDoubleStart() async {
        let engine = makeEngine()
        await engine.startDictation()
        await engine.startDictation()
        #expect(engine.state == .recording)
    }

    @Test("ignores finish when not recording")
    func ignoresStrayFinish() async {
        let inserter = FakeInserter()
        let engine = makeEngine(inserter: inserter)
        await engine.finishDictation()
        #expect(engine.state == .idle)
        #expect(inserter.inserted.value.isEmpty)
    }

    @Test("two overlapping starts only start the recorder once")
    func ignoresOverlappingStart() async {
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        // Neither call is awaited before the other begins, so both run
        // concurrently and can observe each other's in-flight state.
        async let first: Void = engine.startDictation()
        async let second: Void = engine.startDictation()
        _ = await (first, second)
        #expect(recorder.startCount.value == 1)
        #expect(engine.state == .recording)
    }

    @Test("a fast tap does not strand the engine mid-recording")
    func fastTapCompletesDictation() async {
        let inserter = FakeInserter()
        let engine = makeEngine(inserter: inserter)
        // Simulates onPress starting a Task and onRelease firing immediately
        // after: startDictation() is in flight, unawaited, when
        // finishDictation() is called.
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        await engine.finishDictation()
        await startTask.value
        #expect(engine.state == .idle)
        #expect(!inserter.inserted.value.isEmpty)
    }

    @Test("cancels an in-progress recording")
    func cancelsRecording() async {
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        await engine.startDictation()
        await engine.cancelDictation()
        #expect(engine.state == .idle)
        #expect(recorder.cancelled.value)
    }

    @Test("ignores cancel when not recording")
    func ignoresStrayCancel() async {
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        await engine.cancelDictation()
        #expect(engine.state == .idle)
        #expect(!recorder.cancelled.value)
    }
}
