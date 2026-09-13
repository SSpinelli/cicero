import AppKit
import CiceroKit

/// A small floating pill near the bottom of the screen showing dictation
/// state. Borderless, non-activating, and never steals focus from the app the
/// user is dictating into.
@MainActor
final class HUDWindow {

    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    /// Auto-dismiss timer for the `.failed` state only.
    ///
    /// The panel is borderless, ignores mouse events, and has no close
    /// control, so a `.failed` HUD left showing has no way for the user to
    /// dismiss it themselves — unlike the menu, which the user opens on
    /// their own to check status, this pill is parked over their screen
    /// uninvited. `DictationEngine` correctly holds `state == .failed` until
    /// the next dictation (that's load-bearing for the menu), so the fix
    /// lives entirely here in presentation: schedule a delayed `hide()`
    /// whenever a failure is shown, and cancel it on every other path so a
    /// stale timer from a past failure can never hide a HUD that a new
    /// dictation just raised.
    private var autoHideTask: Task<Void, Never>?

    init() {
        // NSPanel, not NSWindow: `.nonactivatingPanel` is a panel-only style
        // mask and is inert on a plain NSWindow. Combined with
        // `becomesKeyOnlyIfNeeded`, this keeps the caret in the app the user
        // is dictating into — showing the HUD must never steal focus.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hasShadow = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.marble.cgColor
        container.layer?.cornerRadius = 22
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.bronze.withAlphaComponent(0.4).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.frame = NSRect(x: 18, y: 16, width: 12, height: 12)
        container.addSubview(dot)

        label.frame = NSRect(x: 40, y: 12, width: 168, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.basalt
        container.addSubview(label)

        window.contentView = container
    }

    func show(state: DictationState) {
        // Cancel any pending auto-hide unconditionally before deciding
        // whether to schedule a new one: without this, a timer armed by a
        // previous `.failed` state could fire mid-recording and hide a HUD
        // that should still be on screen, leaving the user speaking with no
        // feedback at all.
        autoHideTask?.cancel()
        autoHideTask = nil

        label.stringValue = caption(for: state)
        dot.layer?.backgroundColor = color(for: state).cgColor
        position()
        window.orderFrontRegardless()

        if case .failed = state {
            autoHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        window.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96))
    }

    private func caption(for state: DictationState) -> String {
        switch state {
        case .idle:         return "Pronto"
        case .recording:    return "Ouvindo…"
        case .transcribing: return "Transcrevendo…"
        case .polishing:    return "Polindo…"
        case .inserting:    return "Inserindo…"
        case .failed:       return "Algo deu errado"
        }
    }

    private func color(for state: DictationState) -> NSColor {
        switch state {
        case .recording:            return Palette.tyrianPurple
        case .transcribing, .polishing, .inserting: return Palette.bronze
        case .idle:                 return Palette.laurel
        case .failed:               return .systemRed
        }
    }
}
