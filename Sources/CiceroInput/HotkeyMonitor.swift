import AppKit
import CiceroKit
@preconcurrency import CoreGraphics
import Foundation

/// Watches for the push-to-talk hotkey system-wide via a CoreGraphics event tap.
///
/// Requires Accessibility permission, which the app needs anyway to post the
/// synthetic ⌘V that inserts text.
@MainActor
public final class HotkeyMonitor {

    private let hotkey: Hotkey
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressState = HotkeyPressState()

    /// `onCancel` fires when Escape is pressed while the hotkey is held —
    /// the spec's `recording --Esc--> idle` transition. It replaces the
    /// release for that dictation: no `onRelease` follows it.
    public init(hotkey: Hotkey = .defaultHotkey,
                onPress: @escaping @MainActor () -> Void,
                onRelease: @escaping @MainActor () -> Void,
                onCancel: @escaping @MainActor () -> Void) {
        self.hotkey = hotkey
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    public func start() throws {
        guard tap == nil else { return }

        // `.flagsChanged` is not optional here: releasing a chord lifts its
        // keys in hardware scan order, so the modifiers routinely come up
        // before the key does. Without this bit the tap never learns that ⌃⌥
        // were released, and a user who holds Space while letting the
        // modifiers go would keep recording forever.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            },
            userInfo: context) else {
            // tapCreate returns nil when Accessibility permission has not been
            // granted — the realistic cause at a correctly-formed call site
            // like this one, though the API can return nil for other reasons too.
            throw CiceroError.accessibilityNotGranted
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Disabling the tap only stops events; the Mach port stays alive
            // and keeps its receive right until it is invalidated. Dropping
            // the reference without this leaks the port every start/stop
            // cycle — cheap today, since `stop()` runs once at teardown, but
            // it is the kind of leak that only shows up once something starts
            // cycling the monitor.
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        pressState = HotkeyPressState()
    }

    /// Maps one tap event onto `HotkeyPressState`'s pure decision and performs
    /// its side effects. All of the *judgment* lives in `HotkeyPressState`; the
    /// only thing decided here is which `EventKind`, if any, a `CGEventType` is.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // macOS disables a tap that takes too long; re-enable it. Any key-up
        // that happened during the dead window never reached us, so drop the
        // held state rather than silently eating the next press.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            pressState.tapReenabled()
            return passthrough
        }

        let kind: HotkeyPressState.EventKind
        switch type {
        case .keyDown:      kind = .keyDown
        case .keyUp:        kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default:            return passthrough
        }

        let outcome = pressState.handle(
            kind,
            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            hotkey: hotkey)

        switch outcome.action {
        case .press: onPress()
        case .release: onRelease()
        case .cancel: onCancel()
        case .none: break
        }

        return outcome.swallowsEvent ? nil : passthrough
    }
}
