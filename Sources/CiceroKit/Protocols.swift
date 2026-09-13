// The five ports between `DictationEngine` and the outside world. Each one is
// implemented in exactly one module (CiceroAudio, CiceroWhisper, CiceroPolish,
// CiceroInput), and swapping an implementation is supposed to mean touching
// that module alone — so what the engine relies on has to be written down
// here, not inferred from whichever implementation happens to exist today.
//
// Two rules cut across all of them:
//
// - **Always return.** The engine awaits these calls on the main actor, and
//   some of them run while it holds a dictation gate. A call that blocks
//   forever does not just stall one dictation; it wedges the app. An
//   implementation that talks to hardware or a model must impose its own
//   timeout and fail rather than hang (`MicrophoneRecorder.engineTimeout` is
//   the worked example).
// - **Be `Sendable` and own your concurrency.** The engine is
//   `@MainActor`-isolated and does no locking on their behalf; all of these
//   are called from it and may be re-entered by a later dictation.

/// Captures microphone audio for one dictation.
///
/// Lifecycle: `start()`, then exactly one of `stop()` or `cancel()`.
///
/// Guarantees the engine relies on:
/// - `cancel()` must tolerate being called after a `start()` that threw, and
///   after a `stop()`, and with no `start()` at all. The engine calls it
///   unconditionally when tearing a dictation down, including on the failure
///   path, so it must be a no-op when there is nothing to tear down rather
///   than an error or a crash.
/// - `cancel()` cannot fail. There is nothing useful the engine could do with
///   an error from a teardown, so it is not allowed to throw one.
/// - Either terminator must release the input device. A recorder left
///   capturing is a hot microphone the user did not ask for.
/// - `stop()` must return everything captured up to that moment, in order.
///   Reordered or truncated audio becomes a silently wrong transcript, which
///   is worse than a visible failure.
public protocol AudioRecorder: Sendable {
    /// Begins capturing. Throws `CiceroError.recordingFailed` if the device
    /// cannot be opened; the engine surfaces that and returns to idle.
    func start() async throws
    /// Ends the capture and returns the audio. Throws
    /// `CiceroError.recordingFailed` if no capture was active.
    func stop() async throws -> AudioBuffer
    /// Ends the capture and discards the audio. Never throws; safe to call
    /// in any state.
    func cancel() async
}

/// Turns captured audio into raw text.
///
/// - The engine never calls this with silence: `AudioBuffer.isSilent()` is
///   checked first, so an empty result here means the model heard nothing in
///   audio that was not silent, not that the user said nothing.
/// - Returning an empty or whitespace-only string is allowed and is treated
///   as "nothing was said": the engine returns to idle and inserts nothing.
/// - Throw `CiceroError.transcriptionFailed` for a genuine failure. Unlike
///   polishing, this has no fallback — there is no text without it — so the
///   error is shown to the user.
/// - Loading a model is the implementation's own business. If it needs
///   warm-up, it must do it lazily and single-flight, not make the engine
///   aware of a "prepare" step.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: AudioBuffer) async throws -> String
}

/// Cleans up a raw transcript: punctuation, filler words, tone.
///
/// **Polishing is an enhancement, never a gate.** The engine catches every
/// error from this call and inserts the raw transcript instead, which is the
/// golden rule in code: a broken polisher must still deliver what the user
/// said. Implementations are therefore free to throw
/// `CiceroError.polishingFailed` rather than returning something degraded —
/// but they must not return text the user did not say. Refusing is safe;
/// inventing is not.
///
/// `context` carries the frontmost app so the tone can follow it (more formal
/// in a mail client than in a chat window). It may be `.unknown`.
public protocol TextPolisher: Sendable {
    func polish(_ text: String, context: DictationContext) async throws -> String
}

/// Delivers the finished text to whatever app the user is in.
///
/// - The engine records `lastTranscript` *before* calling this, so a failure
///   here still leaves the words reachable from the menu bar. That ordering
///   is the engine's job, not the inserter's — but it is why an inserter is
///   allowed to fail loudly instead of half-succeeding.
/// - Throw `CiceroError.insertionBlockedBySecureInput` when a password field
///   has focus: macOS drops synthetic key events there, so pasting would
///   silently do nothing, and the user needs to be told where their text went
///   instead.
/// - Any implementation that borrows the clipboard must give it back. The
///   user's own clipboard surviving a dictation is part of the same promise
///   as not losing the dictation itself.
public protocol TextInserter: Sendable {
    func insert(_ text: String) async throws
}

/// Identifies the app the user is dictating into.
///
/// Deliberately cannot fail: context is an input to tone, never a
/// precondition for dictating. When nothing can be determined, return
/// `DictationContext.unknown` — the engine has no error path here and will
/// not delay a dictation over it.
public protocol ContextProvider: Sendable {
    func currentContext() async -> DictationContext
}
