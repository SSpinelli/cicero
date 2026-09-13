import CoreGraphics
import Testing
@testable import CiceroInput

@Suite("Hotkey")
struct HotkeyTests {

    private let space: CGKeyCode = 49   // kVK_Space
    private let keyA: CGKeyCode = 0     // kVK_ANSI_A

    @Test("the default hotkey is control + option + space")
    func defaultIsControlOptionSpace() {
        let hotkey = Hotkey.defaultHotkey
        #expect(hotkey.keyCode == space)
        #expect(hotkey.modifiers.contains(.maskControl))
        #expect(hotkey.modifiers.contains(.maskAlternate))
        #expect(!hotkey.modifiers.contains(.maskCommand))
    }

    @Test("matches the exact combination")
    func matchesExactCombination() {
        #expect(Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl, .maskAlternate]))
    }

    @Test("does not match the wrong key")
    func rejectsWrongKey() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: keyA, flags: [.maskControl, .maskAlternate]))
    }

    @Test("does not match with a modifier missing")
    func rejectsMissingModifier() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl]))
    }

    @Test("does not match with an extra modifier")
    func rejectsExtraModifier() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl, .maskAlternate, .maskCommand]))
    }

    @Test("ignores irrelevant flag bits such as caps lock and numeric pad")
    func ignoresIrrelevantFlags() {
        #expect(Hotkey.defaultHotkey.matches(
            keyCode: space,
            flags: [.maskControl, .maskAlternate, .maskAlphaShift, .maskNumericPad]))
    }
}
