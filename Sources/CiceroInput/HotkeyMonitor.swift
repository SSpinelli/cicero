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

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressState = HotkeyPressState()

    public init(hotkey: Hotkey = .defaultHotkey,
                onPress: @escaping @MainActor () -> Void,
                onRelease: @escaping @MainActor () -> Void) {
        self.hotkey = hotkey
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public func start() throws {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
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
        }
        tap = nil
        runLoopSource = nil
        pressState = HotkeyPressState()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long; re-enable it. Any key-up
        // that happened during the dead window never reached us, so drop the
        // held state rather than silently eating the next press.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            pressState.tapReenabled()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard hotkey.matches(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        let action: HotkeyPressState.Action
        switch type {
        case .keyDown:
            action = pressState.keyDown()
        case .keyUp:
            action = pressState.keyUp()
        default:
            return Unmanaged.passUnretained(event)
        }

        switch action {
        case .press: onPress()
        case .release: onRelease()
        case .none: break
        }

        // Swallow the event so the hotkey does not reach the focused app.
        return nil
    }
}
