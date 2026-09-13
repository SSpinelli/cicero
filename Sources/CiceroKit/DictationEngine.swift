import Foundation
import Observation

/// Orchestrates one dictation: record, transcribe, polish, insert.
///
/// Lives on the main actor so the UI can observe `state` directly. The heavy
/// work happens inside the injected dependencies, which are `Sendable` and
/// manage their own concurrency.
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

    /// The in-flight `startDictation()` work, so `finishDictation()` and
    /// `cancelDictation()` can wait for the recorder to actually finish
    /// starting before touching it — the synchronous `state` claim below
    /// prevents stranding, but only this task ordering prevents `stop()`
    /// or `cancel()` from racing ahead of `recorder.start()`.
    private var startTask: Task<Void, Never>?

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
        // Claim the state before any suspension point. Leaving it `.idle` across
        // these awaits lets a fast tap's finishDictation() observe `.idle`, return
        // early, and strand the engine in a recording that never stops.
        state = .recording
        // The state claim above is not enough on its own: it stops a fast tap
        // from being ignored, but finishDictation()/cancelDictation() could
        // still race ahead of recorder.start() itself, since that call is
        // async. Running the start work as a task that they explicitly await
        // serializes "start" before "stop"/"cancel" without reintroducing the
        // stranding bug.
        let task = Task { @MainActor [self] in
            context = await contextProvider.currentContext()
            do {
                try await recorder.start()
            } catch {
                fail(with: error)
            }
        }
        startTask = task
        await task.value
    }

    /// Happy path only. Task 3 adds the guards and fallbacks.
    public func finishDictation() async {
        guard state == .recording else { return }
        // Never stop a recorder that has not finished starting.
        await startTask?.value
        // The start may have failed while we waited.
        guard state == .recording else { return }
        state = .transcribing
        do {
            let audio = try await recorder.stop()
            let raw = try await transcriber.transcribe(audio)
            state = .polishing
            let text = try await polisher.polish(raw, context: context)
            lastTranscript = text
            state = .inserting
            try await inserter.insert(text)
            state = .idle
        } catch {
            fail(with: error)
        }
    }

    public func cancelDictation() async {
        guard state == .recording else { return }
        state = .idle
        // Never cancel a recorder that has not finished starting.
        await startTask?.value
        // A user-initiated cancel takes precedence over a start that failed
        // while we were waiting for it: re-assert `.idle` so cancelling never
        // surfaces a failure banner for a dictation the user is the one who
        // ended. (See the fix report for the full reasoning.)
        state = .idle
        await recorder.cancel()
    }

    private var isStartable: Bool {
        switch state {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func fail(with error: Error) {
        let message = (error as? CiceroError)?.userMessage ?? error.localizedDescription
        state = .failed(message)
    }
}
