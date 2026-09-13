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
        #expect(recorder.callLog.value == ["start"])
        #expect(engine.state == .recording)
    }

    @Test("a fast tap does not strand the engine, and never stops a recorder that has not started")
    func fastTapCompletesDictation() async {
        // A non-zero delay is essential here: with a zero delay this test
        // would only reach the interleaving it means to test because
        // Task.yield() happens to advance execution by exactly one step,
        // and would silently stop testing anything the moment a scheduler
        // change altered that. The delay makes the interleaving reachable
        // on its own merits.
        let recorder = FakeRecorder(startDelayNanoseconds: 20_000_000) // 20ms
        let inserter = FakeInserter()
        let engine = makeEngine(recorder: recorder, inserter: inserter)
        // Simulates onPress starting a Task and onRelease firing immediately
        // after: startDictation() is in flight, unawaited, when
        // finishDictation() is called.
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        await engine.finishDictation()
        await startTask.value
        #expect(engine.state == .idle)
        #expect(!inserter.inserted.value.isEmpty)
        // "start" must precede "stop" — recorder.stop() must never run before
        // recorder.start() has finished — and there must be no orphaned late
        // "start" left running after the dictation has already completed.
        #expect(recorder.callLog.value == ["start", "stop"])
        #expect(recorder.startCount.value == 1)
    }

    @Test("cancelling during a slow start waits for it, then cancels exactly once")
    func cancelDuringSlowStartWaitsThenCancels() async {
        let recorder = FakeRecorder(startDelayNanoseconds: 20_000_000) // 20ms
        let engine = makeEngine(recorder: recorder)
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        await engine.cancelDictation()
        await startTask.value
        #expect(engine.state == .idle)
        #expect(recorder.callLog.value == ["start", "cancel"])
        #expect(recorder.startCount.value == 1)
    }

    @Test("cancelling a start that fails still leaves the engine idle, not failed")
    func cancelAfterFailedStartEndsIdle() async {
        // Design decision: a user-initiated cancel takes precedence over a
        // start that failed while the cancel was waiting for it. The user
        // already ended this dictation; surfacing a failure banner for a
        // session they themselves cancelled would misattribute the outcome.
        let recorder = FakeRecorder(startError: .recordingFailed("mic indisponível"),
                                     startDelayNanoseconds: 20_000_000)
        let engine = makeEngine(recorder: recorder)
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        await engine.cancelDictation()
        await startTask.value
        #expect(engine.state == .idle)
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

    @Test("a second start landing inside a cancel's wait is rejected, not admitted")
    func startDuringCancelWaitIsRejected() async {
        let recorder = FakeRecorder(startDelayNanoseconds: 20_000_000) // 20ms
        let engine = makeEngine(recorder: recorder)
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        // A cancel begins while the start above is still in flight...
        let cancelTask = Task { await engine.cancelDictation() }
        await Task.yield()
        // ...and a second start must be rejected outright while the cancel
        // is tearing down, not admitted the way it would be if `state` had
        // already been released to `.idle`.
        await engine.startDictation()
        await startTask.value
        await cancelTask.value
        #expect(recorder.startCount.value == 1)
        #expect(recorder.callLog.value == ["start", "cancel"])
        // `.idle` is a state from which the next dictation behaves
        // correctly (isStartable admits it, and no recorder session is
        // left running underneath it).
        #expect(engine.state == .idle)
    }

    @Test("a cancel that lands inside finish's wait wins: stop() never runs")
    func cancelDuringFinishWaitPreventsStop() async {
        // NOTE: verified this does not discriminate against round-2 either
        // — with only these three events (no stray start admitted), round
        // 2's plain `state == .recording` check on finish's side already
        // happens to fail once cancel's own (round-2) early `state = .idle`
        // has landed. It is kept as coverage for this three-event shape
        // under the new design; `fourEventCancelAdmittingStrayStartMustNotFoolFinish`
        // below is the test that actually reproduces the reviewer's finding.
        let recorder = FakeRecorder(startDelayNanoseconds: 20_000_000) // 20ms
        let engine = makeEngine(recorder: recorder)
        let startTask = Task { await engine.startDictation() }
        await Task.yield()
        // finishDictation() begins first and suspends waiting for the slow
        // start to finish...
        let finishTask = Task { await engine.finishDictation() }
        await Task.yield()
        // ...then a cancel lands while finish is still waiting.
        await engine.cancelDictation()
        await finishTask.value
        await startTask.value
        let log = recorder.callLog.value
        // stop() must never be logged before start(), and never without a
        // preceding start for the same dictation.
        if let stopIndex = log.firstIndex(of: "stop") {
            #expect(log[..<stopIndex].contains("start"))
        }
        #expect(log == ["start", "cancel"])
        #expect(engine.state == .idle)
    }

    @Test("a stray start admitted mid-cancel must not fool a racing finish into stopping it")
    func fourEventCancelAdmittingStrayStartMustNotFoolFinish() async {
        // Reproduces the reviewer's four-event variant precisely: start(A),
        // finish(A) begins waiting on A's slow start, cancel(A) begins
        // (which, under the pre-round-3 design, released `state` to `.idle`
        // immediately and so admitted a stray start(B) here), and finally
        // finish(A) resumes and must not mistake B's `.recording` claim for
        // its own dictation's and call recorder.stop() on B's unstarted
        // recording. Under the round-3 design B must never be admitted at
        // all: `isCancelling` keeps the engine non-startable for the whole
        // span of the cancel, independent of `state`.
        let recorder = FakeRecorder(startDelayNanoseconds: 20_000_000) // 20ms
        let engine = makeEngine(recorder: recorder)

        let startA = Task { await engine.startDictation() }
        await Task.yield()
        let finishA = Task { await engine.finishDictation() }
        await Task.yield()
        let cancelA = Task { await engine.cancelDictation() }
        await Task.yield()
        // The stray start (B) arrives while cancel(A) is still tearing down.
        let startB = Task { await engine.startDictation() }

        await startA.value
        await finishA.value
        await cancelA.value
        await startB.value

        // B must never have reached the recorder at all: exactly one
        // "start" (A's), and finish must never have called "stop" on it.
        #expect(recorder.startCount.value == 1)
        #expect(!recorder.callLog.value.contains("stop"))
    }

    @Test("two concurrent cancels only cancel the recorder once")
    func ignoresOverlappingCancel() async {
        // NOTE: this invariant (5) was already satisfied before round 3.
        // Claiming `isCancelling = true` synchronously, with no `await`
        // between the guard check and the claim, makes the claim atomic on
        // the MainActor's serial executor — the same reason round 1's
        // double-start guard already worked. This test does not fail
        // against the round-2 code (verified: it passes there too); it is
        // included as explicit, permanent coverage for invariant 5 under
        // the new design, not as a regression reproduction.
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        await engine.startDictation()
        // Neither call is awaited before the other begins, so both run
        // concurrently and can observe each other's in-flight state.
        async let first: Void = engine.cancelDictation()
        async let second: Void = engine.cancelDictation()
        _ = await (first, second)
        #expect(recorder.callLog.value.filter { $0 == "cancel" }.count == 1)
        #expect(engine.state == .idle)
    }
}
