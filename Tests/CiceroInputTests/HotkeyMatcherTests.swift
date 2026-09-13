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

@Suite("HotkeyPressState")
struct HotkeyPressStateTests {

    @Test("a key-down while not held fires press and becomes held")
    func keyDownFromReleasedFiresPress() {
        var state = HotkeyPressState()
        #expect(state.keyDown() == .press)
        #expect(state.isHeld)
    }

    @Test("repeated key-down while already held is ignored")
    func repeatedKeyDownIsIgnored() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        #expect(state.keyDown() == .none)
        #expect(state.keyDown() == .none)
        #expect(state.isHeld)
    }

    @Test("a key-up while held fires release and becomes released")
    func keyUpFromHeldFiresRelease() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        #expect(state.keyUp() == .release)
        #expect(!state.isHeld)
    }

    @Test("a key-up while not held is ignored")
    func keyUpFromReleasedIsIgnored() {
        var state = HotkeyPressState()
        #expect(state.keyUp() == .none)
        #expect(!state.isHeld)
    }

    @Test("a full press/release cycle can repeat")
    func pressReleaseCycleRepeats() {
        var state = HotkeyPressState()
        #expect(state.keyDown() == .press)
        #expect(state.keyUp() == .release)
        #expect(state.keyDown() == .press)
        #expect(state.keyUp() == .release)
    }

    @Test("re-enabling the tap while held drops the held state")
    func tapReenabledClearsHeldState() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        state.tapReenabled()
        #expect(!state.isHeld)
    }

    @Test("re-enabling the tap while not held is a no-op")
    func tapReenabledWhileReleasedStaysReleased() {
        var state = HotkeyPressState()
        state.tapReenabled()
        #expect(!state.isHeld)
    }

    @Test("""
    the defect this fixes: a tap disable during a held key must not eat the \
    next press or produce an unpaired release
    """)
    func tapDisableDuringHeldKeyDoesNotEatNextPress() {
        var state = HotkeyPressState()

        // Key goes down, tap dies mid-hold — the key-up that would have
        // arrived never does, because the tap is dead.
        #expect(state.keyDown() == .press)
        state.tapReenabled()

        // The user's *next* real press must still register as a press, not
        // be silently swallowed because isHeld was still stuck at true.
        #expect(state.keyDown() == .press)
        // ...and its key-up must produce exactly one paired release, not an
        // unpaired release with no matching press.
        #expect(state.keyUp() == .release)
    }
}
