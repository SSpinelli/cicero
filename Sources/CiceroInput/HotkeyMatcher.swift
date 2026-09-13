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
