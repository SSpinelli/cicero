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

    @Test("""
    does not match with a modifier missing — the key-DOWN rule, which is what \
    keeps the hotkey from firing on unrelated typing
    """)
    func rejectsMissingModifier() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl]))
        // This strictness is deliberately *not* applied to key-up or to
        // flags-changed: see the HotkeyPressState routing tests below, where
        // requiring it is exactly the defect that wedged the app.
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

    // MARK: - modifiersHeld: "is the chord still down?", not "does this start it?"

    @Test("the chord counts as held while every required modifier is down")
    func modifiersHeldWhenAllPresent() {
        #expect(Hotkey.defaultHotkey.modifiersHeld(in: [.maskControl, .maskAlternate]))
    }

    @Test("an extra modifier pressed mid-dictation does not end the chord")
    func modifiersHeldToleratesExtras() {
        #expect(Hotkey.defaultHotkey.modifiersHeld(in: [.maskControl, .maskAlternate, .maskShift]))
    }

    @Test("lifting a required modifier ends the chord")
    func modifiersNotHeldWhenOneIsLifted() {
        #expect(!Hotkey.defaultHotkey.modifiersHeld(in: [.maskControl]))
        #expect(!Hotkey.defaultHotkey.modifiersHeld(in: []))
    }

    @Test("caps lock alone neither holds nor breaks the chord")
    func modifiersHeldIgnoresIrrelevantFlags() {
        #expect(Hotkey.defaultHotkey.modifiersHeld(
            in: [.maskControl, .maskAlternate, .maskAlphaShift]))
        #expect(!Hotkey.defaultHotkey.modifiersHeld(in: [.maskAlphaShift]))
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

    @Test("modifiers changing while not held is ignored")
    func modifiersChangedWhileReleasedIsIgnored() {
        var state = HotkeyPressState()
        #expect(state.modifiersChanged(stillSatisfied: false) == .none)
        #expect(!state.isHeld)
    }

    @Test("modifiers still satisfied while held changes nothing")
    func modifiersStillSatisfiedKeepsHolding() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        #expect(state.modifiersChanged(stillSatisfied: true) == .none)
        #expect(state.isHeld)
    }

    @Test("modifiers no longer satisfied while held fires release")
    func modifiersDroppedWhileHeldFiresRelease() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        #expect(state.modifiersChanged(stillSatisfied: false) == .release)
        #expect(!state.isHeld)
    }

    @Test("a second flags change after a release does not fire a second release")
    func modifiersDroppedTwiceFiresOneRelease() {
        var state = HotkeyPressState()
        _ = state.keyDown()
        #expect(state.modifiersChanged(stillSatisfied: false) == .release)
        #expect(state.modifiersChanged(stillSatisfied: false) == .none)
    }
}

/// The full routing decision for one tap event, driven exactly as
/// `HotkeyMonitor` drives it — the event kind, key code and flags the tap
/// would deliver — so both hand-off-the-keyboard orders are covered without
/// installing an event tap.
@Suite("HotkeyPressState event routing")
struct HotkeyPressStateRoutingTests {

    private let hotkey = Hotkey.defaultHotkey
    private let space: CGKeyCode = 49
    private let keyA: CGKeyCode = 0
    private let chord: CGEventFlags = [.maskControl, .maskAlternate]

    @Test("""
    the defect this fixes: lifting the modifiers before the key must end the \
    dictation, not wedge it held forever
    """)
    func modifierFirstReleaseEndsTheDictation() {
        var state = HotkeyPressState()

        // ⌃⌥ down, then Space: the dictation starts.
        #expect(state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
                == .init(action: .press, swallowsEvent: true))

        // The hand lifts. Control comes up first — this event was not even
        // subscribed to before the fix.
        #expect(state.handle(.flagsChanged, keyCode: 59, flags: [.maskAlternate], hotkey: hotkey)
                == .init(action: .release, swallowsEvent: false))
        #expect(!state.isHeld)

        // Option follows: no second release for one dictation.
        #expect(state.handle(.flagsChanged, keyCode: 58, flags: [], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))

        // Space comes up last, carrying no modifiers at all. Before the fix
        // this failed the strict match, left isHeld stuck at true, and killed
        // the hotkey for the rest of the session.
        #expect(state.handle(.keyUp, keyCode: space, flags: [], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))

        // The proof that nothing is wedged: the next press still works.
        #expect(state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
                == .init(action: .press, swallowsEvent: true))
    }

    @Test("releasing the key before the modifiers also ends the dictation, exactly once")
    func keyFirstReleaseEndsTheDictation() {
        var state = HotkeyPressState()

        #expect(state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
                == .init(action: .press, swallowsEvent: true))

        // Space up while ⌃⌥ are still down: a release, and swallowed so the
        // focused app never sees the space.
        #expect(state.handle(.keyUp, keyCode: space, flags: chord, hotkey: hotkey)
                == .init(action: .release, swallowsEvent: true))

        // The modifiers coming up afterwards must not fire a second release.
        #expect(state.handle(.flagsChanged, keyCode: 59, flags: [.maskAlternate], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
        #expect(state.handle(.flagsChanged, keyCode: 58, flags: [], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
    }

    @Test("a key-up whose key-down we never swallowed passes through untouched")
    func unrelatedKeyUpIsNotSwallowed() {
        var state = HotkeyPressState()
        // Someone typing an ordinary space: the key-down did not match, so the
        // key-up must reach the focused app or their space bar stops working.
        #expect(state.handle(.keyDown, keyCode: space, flags: [], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
        #expect(state.handle(.keyUp, keyCode: space, flags: [], hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
    }

    @Test("an unrelated key is never touched, held or not")
    func unrelatedKeyIsIgnored() {
        var state = HotkeyPressState()
        #expect(state.handle(.keyDown, keyCode: keyA, flags: chord, hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))

        _ = state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
        #expect(state.handle(.keyUp, keyCode: keyA, flags: chord, hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
        #expect(state.isHeld, "outra tecla não pode encerrar a ditada")
    }

    @Test("key repeat while held neither re-fires nor leaks the key to the focused app")
    func keyRepeatIsSwallowedWithoutRefiring() {
        var state = HotkeyPressState()
        _ = state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
        #expect(state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
                == .init(action: .none, swallowsEvent: true))
    }

    @Test("modifier events are never swallowed, even the one that ends the dictation")
    func modifierEventsAlwaysReachTheSystem() {
        var state = HotkeyPressState()
        _ = state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
        let outcome = state.handle(.flagsChanged, keyCode: 59, flags: [], hotkey: hotkey)
        #expect(outcome.action == .release)
        #expect(!outcome.swallowsEvent, "engolir um evento de modificador corrompe o estado de teclas dos outros apps")
    }

    @Test("an extra modifier pressed mid-dictation does not end it")
    func extraModifierDoesNotRelease() {
        var state = HotkeyPressState()
        _ = state.handle(.keyDown, keyCode: space, flags: chord, hotkey: hotkey)
        #expect(state.handle(.flagsChanged,
                             keyCode: 56,
                             flags: [.maskControl, .maskAlternate, .maskShift],
                             hotkey: hotkey)
                == .init(action: .none, swallowsEvent: false))
        #expect(state.isHeld)
    }
}
