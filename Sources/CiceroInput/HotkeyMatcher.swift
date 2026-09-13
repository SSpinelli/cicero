import CoreGraphics

/// A push-to-talk key combination.
public struct Hotkey: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let modifiers: CGEventFlags

    public init(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control + Option + Space. Deliberately not `fn`, which collides with
    /// macOS's own emoji and dictation behavior.
    public static let defaultHotkey = Hotkey(
        keyCode: 49, // kVK_Space
        modifiers: [.maskControl, .maskAlternate])

    /// Only these bits are considered; caps lock, numeric pad and coalesced
    /// flags must not defeat a match.
    private static let relevant: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]

    /// Whether this event *starts* the hotkey: the right key with exactly the
    /// right modifiers. Deliberately strict — this is the rule that stops the
    /// hotkey firing on unrelated keystrokes, so it is the one used for
    /// key-down. It is the wrong rule for deciding when a held hotkey *ends*;
    /// see `modifiersHeld(in:)`.
    public func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let significant = flags.intersection(Self.relevant)
        return significant == modifiers.intersection(Self.relevant)
    }

    /// Whether `flags` still carries every modifier this hotkey requires.
    ///
    /// A subset test, not `matches`'s exact equality, because it answers a
    /// different question: "is the chord still being held?" A stray Shift
    /// pressed mid-sentence is no reason to end the user's dictation, but
    /// lifting Control or Option is — that is the user's hand leaving the
    /// keyboard.
    public func modifiersHeld(in flags: CGEventFlags) -> Bool {
        let required = modifiers.intersection(Self.relevant)
        return flags.intersection(required) == required
    }
}

/// Tracks whether the hotkey is currently held down, deciding when a
/// matching key-down/key-up pair should actually fire a press or release.
///
/// Deliberately `CGEvent`-free so it is a plain, unit-testable value type;
/// `HotkeyMonitor` owns one instance and drives it from the event tap
/// callback.
struct HotkeyPressState: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        case press
        case release
        case cancel
    }

    /// kVK_Escape. Escape pressed while the hotkey is held is the spec's
    /// `recording --Esc--> idle` transition: throw this dictation away
    /// instead of transcribing it.
    static let cancelKeyCode: CGKeyCode = 53

    private(set) var isHeld = false

    /// A matching key-down arrived. Key repeat fires key-down continuously
    /// while the key stays down; only the first one should produce `.press`.
    mutating func keyDown() -> Action {
        guard !isHeld else { return .none }
        isHeld = true
        return .press
    }

    /// A key-up for the hotkey's key arrived while it was held.
    ///
    /// The caller must *not* have required a modifier match: releasing a
    /// chord lifts its keys in whatever order the hardware happens to scan,
    /// so by the time Space comes up, Control and Option are routinely
    /// already gone and the event carries no modifiers at all. Requiring an
    /// exact match here is what used to strand `isHeld` at `true` forever —
    /// microphone live, HUD stuck, hotkey dead for the rest of the session.
    mutating func keyUp() -> Action {
        guard isHeld else { return .none }
        isHeld = false
        return .release
    }

    /// The modifier flags changed. `stillSatisfied` is whether the hotkey's
    /// required modifiers are all still down (`Hotkey.modifiersHeld(in:)`).
    ///
    /// Covers the other release order: holding Space while lifting ⌃⌥ ends
    /// the dictation, because the user's hand has left the chord. Without
    /// this, that release arrives only as `.flagsChanged` — an event type the
    /// tap did not even subscribe to — and the dictation would never end.
    mutating func modifiersChanged(stillSatisfied: Bool) -> Action {
        guard isHeld, !stillSatisfied else { return .none }
        isHeld = false
        return .release
    }

    /// The cancel key went down while the hotkey was held.
    ///
    /// Clears `isHeld` deliberately: the dictation is over, so the hotkey
    /// key-up that follows must not also fire a release and ask the engine
    /// to finish what was just thrown away.
    mutating func cancelKeyDown() -> Action {
        guard isHeld else { return .none }
        isHeld = false
        return .cancel
    }

    /// The tap was disabled and has just been re-enabled. Any key-up that
    /// happened during the dead window never reached us, so treat the key as
    /// released rather than silently eating the next press.
    mutating func tapReenabled() {
        isHeld = false
    }
}

extension HotkeyPressState {

    /// The kinds of tap event that can mean something to the hotkey. A plain
    /// enum rather than `CGEventType` so the whole routing decision below is
    /// testable without fabricating events or installing a tap.
    enum EventKind: Equatable, Sendable {
        case keyDown
        case keyUp
        case flagsChanged
    }

    /// What one event means, and whether the focused app may see it.
    struct Outcome: Equatable, Sendable {
        let action: Action
        /// Whether to withhold the event from the focused app. True only for
        /// events that belong to the hotkey itself.
        let swallowsEvent: Bool
    }

    /// The complete decision for one tap event. Lives here, not in the tap
    /// callback, so every branch is exercised by plain unit tests.
    ///
    /// The three event kinds use deliberately different matching rules:
    ///
    /// - `.keyDown` matches strictly (`Hotkey.matches`). That is what keeps
    ///   the hotkey from firing on unrelated typing.
    /// - `.keyUp` matches on key code alone, and only while held. A key-up
    ///   for a key we swallowed the key-down of is that key's release, no
    ///   matter which modifiers survived to this instant. The `isHeld`
    ///   condition is what keeps an ordinary Space key-up — one whose
    ///   key-down we let through — flowing to the focused app untouched.
    /// - `.flagsChanged` never swallows. Modifier events belong to the whole
    ///   system; eating one would leave other apps believing a modifier is
    ///   still down.
    mutating func handle(_ kind: EventKind,
                         keyCode: CGKeyCode,
                         flags: CGEventFlags,
                         hotkey: Hotkey) -> Outcome {
        switch kind {
        case .keyDown:
            // Escape only means "cancel" while a dictation is actually being
            // held; at every other moment it belongs to the focused app and
            // is neither acted on nor swallowed.
            if keyCode == Self.cancelKeyCode, isHeld {
                return Outcome(action: cancelKeyDown(), swallowsEvent: true)
            }
            guard hotkey.matches(keyCode: keyCode, flags: flags) else {
                return Outcome(action: .none, swallowsEvent: false)
            }
            return Outcome(action: keyDown(), swallowsEvent: true)

        case .keyUp:
            guard keyCode == hotkey.keyCode, isHeld else {
                return Outcome(action: .none, swallowsEvent: false)
            }
            return Outcome(action: keyUp(), swallowsEvent: true)

        case .flagsChanged:
            let action = modifiersChanged(stillSatisfied: hotkey.modifiersHeld(in: flags))
            // Not swallowed even when it fires a release. One consequence,
            // accepted deliberately: the hotkey key-up that arrives after a
            // modifier-first release is no longer held, so it reaches the
            // focused app as an unpaired key-up. Apps act on key-down, and
            // that key-down was swallowed, so nothing is typed — whereas
            // eating modifier events would corrupt every other app's idea of
            // which keys are down.
            return Outcome(action: action, swallowsEvent: false)
        }
    }
}
