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

    public func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let significant = flags.intersection(Self.relevant)
        return significant == modifiers.intersection(Self.relevant)
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
    }

    private(set) var isHeld = false

    /// A matching key-down arrived. Key repeat fires key-down continuously
    /// while the key stays down; only the first one should produce `.press`.
    mutating func keyDown() -> Action {
        guard !isHeld else { return .none }
        isHeld = true
        return .press
    }

    /// A matching key-up arrived.
    mutating func keyUp() -> Action {
        guard isHeld else { return .none }
        isHeld = false
        return .release
    }

    /// The tap was disabled and has just been re-enabled. Any key-up that
    /// happened during the dead window never reached us, so treat the key as
    /// released rather than silently eating the next press.
    mutating func tapReenabled() {
        isHeld = false
    }
}
