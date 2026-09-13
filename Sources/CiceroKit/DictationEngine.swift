import Foundation
import Observation

/// Orchestrates one dictation: record, transcribe, polish, insert.
///
/// Lives on the main actor so the UI can observe `state` directly. The heavy
/// work happens inside the injected dependencies, which are `Sendable` and
/// manage their own concurrency.
///
/// ## Concurrency design
///
/// `state` and `startTask` alone cannot identify "the current dictation":
/// neither survives an `await`, so after any suspension point they may
/// belong to a *later* dictation than the one an in-flight operation started
/// with. Re-checking `state` after an `await` is therefore not enough — it
/// can be checking a different dictation's state. Every operation instead
/// captures a private `generation` counter into a local before its first
/// suspension point, and re-validates that it still owns the current
/// generation after every subsequent suspension point before it mutates
/// shared state or touches the recorder. If it does not, a newer dictation
/// owns the engine and the operation returns without acting.
///
/// `isCancelling` is a second, private piece of state (deliberately not a
/// `DictationState` case — that enum is public and switched over
/// exhaustively by later tasks, and its cases are fixed by the spec). It
/// keeps the engine non-startable for the whole span of a cancel's teardown:
/// releasing `state` to `.idle` before `recorder.cancel()` has actually run
/// is exactly what would let a racing `startDictation()` slip in underneath
/// an in-progress cancel.
@MainActor
@Observable
public final class DictationEngine {
    public private(set) var state: DictationState = .idle
    public private(set) var lastTranscript: String?

    private let recorder: any AudioRecorder
    private let transcriber: any Transcriber
    private let polisher: any TextPolisher
    private let inserter: any TextInserter
    private let contextProvider: any ContextProvider

    private var context: DictationContext = .unknown

    /// Identifies "the current dictation." Bumped once per accepted
    /// `startDictation()`. See the type-level doc comment.
    private var generation = 0

    /// The in-flight start work for the current generation. Operations that
    /// need to wait for a start to finish capture this into a local before
    /// their first `await` and act on that local — never by re-reading
    /// `startTask` after a suspension, since a later dictation may have
    /// replaced it by then.
    private var startTask: Task<Void, Never>?

    /// True from the moment a cancel is accepted until its teardown
    /// (`recorder.cancel()`) has completed. See the type-level doc comment.
    private var isCancelling = false

    public init(recorder: any AudioRecorder,
                transcriber: any Transcriber,
                polisher: any TextPolisher,
                inserter: any TextInserter,
                contextProvider: any ContextProvider) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.polisher = polisher
        self.inserter = inserter
        self.contextProvider = contextProvider
    }

    public func startDictation() async {
        guard isStartable else { return }
        // Claim the state and a fresh generation before any suspension
        // point. Leaving `state` at `.idle` across the awaits below lets a
        // fast tap's finishDictation() observe `.idle`, return early, and
        // strand the engine in a recording that never stops.
        generation += 1
        let myGeneration = generation
        state = .recording
        // The claim above stops a fast tap from being ignored, but
        // finishDictation()/cancelDictation() could still race ahead of
        // recorder.start() itself, since that call is async. Running the
        // start work as a task that they explicitly await serializes
        // "start" before "stop"/"cancel" without reintroducing the
        // stranding bug. Each write inside re-checks its generation in case
        // a cancel has since claimed this dictation.
        let task = Task { @MainActor [self] in
            context = await contextProvider.currentContext()
            guard isCurrent(myGeneration) else { return }
            do {
                try await recorder.start()
            } catch {
                guard isCurrent(myGeneration) else { return }
                fail(with: error)
            }
        }
        startTask = task
        // Link this unstructured task to the caller's own cancellation:
        // without this, cancelling the Task that is running startDictation()
        // (e.g. the app tearing down) would leave `task` detached and still
        // free to call recorder.start() with nothing left to stop it.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Happy path only. Task 3 adds the guards and fallbacks.
    public func finishDictation() async {
        guard state == .recording, !isCancelling else { return }
        let myGeneration = generation
        let task = startTask
        // Never stop a recorder that has not finished starting.
        await task?.value
        // A cancel may have claimed this dictation while we waited — it
        // sets `isCancelling` synchronously before it too awaits `task`, so
        // this check is what makes the outcome deterministic regardless of
        // which of finish/cancel happens to resume first. (For any later
        // suspension point below, only `isCurrent` needs checking: once
        // `state` leaves `.recording` here, cancelDictation()'s own entry
        // guard can no longer accept a concurrent cancel for this
        // dictation.)
        guard isCurrent(myGeneration), state == .recording, !isCancelling else { return }
        state = .transcribing
        do {
            let audio = try await recorder.stop()
            guard isCurrent(myGeneration) else { return }
            let raw = try await transcriber.transcribe(audio)
            guard isCurrent(myGeneration) else { return }
            state = .polishing
            let text = try await polisher.polish(raw, context: context)
            guard isCurrent(myGeneration) else { return }
            lastTranscript = text
            state = .inserting
            try await inserter.insert(text)
            guard isCurrent(myGeneration) else { return }
            state = .idle
        } catch {
            guard isCurrent(myGeneration) else { return }
            fail(with: error)
        }
    }

    public func cancelDictation() async {
        guard state == .recording, !isCancelling else { return }
        let myGeneration = generation
        // Claimed synchronously, before any suspension point: this is what
        // keeps the engine non-startable for the whole span of the cancel,
        // so a racing startDictation() cannot slip in underneath it. A
        // second concurrent cancelDictation() call also fails this guard
        // the moment it is set, so only one cancel ever proceeds.
        isCancelling = true
        let task = startTask
        // Never cancel a recorder that has not finished starting.
        await task?.value
        guard isCurrent(myGeneration) else {
            // Superseded while we waited — nothing of ours remains to tear
            // down; release our hold without touching the newer dictation.
            isCancelling = false
            return
        }
        // Design decision (unchanged since round 2): a user-initiated
        // cancel takes precedence over a start that failed while we waited
        // for it. The user already ended this dictation; surfacing a
        // failure banner for a session they themselves cancelled would
        // misattribute the outcome. `fail(with:)` may have run while we
        // awaited `task`, so `state` is reasserted below regardless.
        await recorder.cancel()
        state = .idle
        isCancelling = false
    }

    private var isStartable: Bool {
        guard !isCancelling else { return false }
        switch state {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Whether `generation` still identifies the dictation captured under
    /// `generationAtCapture`. Used after every suspension point to detect
    /// that a different dictation now owns the engine.
    private func isCurrent(_ generationAtCapture: Int) -> Bool {
        generation == generationAtCapture
    }

    private func fail(with error: Error) {
        let message = (error as? CiceroError)?.userMessage ?? error.localizedDescription
        state = .failed(message)
    }
}
