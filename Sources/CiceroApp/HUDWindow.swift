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
    private let container: NSView

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

    /// Pill geometry. The panel is no longer a fixed 220×44: a `.failed`
    /// state carries the message that tells the user where their words went
    /// ("Campo de senha em foco. O texto ficou disponível no menu."), which
    /// does not fit on one 168 pt line. The pill is measured against the
    /// caption and grows — up to `maxWidth` and `maxLines` — so the message
    /// is readable, and stays at its old size for the ordinary one-word
    /// captions, which are the ones on screen almost all the time.
    private enum Metrics {
        static let dotDiameter: CGFloat = 12
        static let leadingInset: CGFloat = 18
        static let gap: CGFloat = 10
        static let trailingInset: CGFloat = 18
        static let verticalPadding: CGFloat = 12
        static let minWidth: CGFloat = 220
        static let maxWidth: CGFloat = 380
        static let minHeight: CGFloat = 44
        static let cornerRadius: CGFloat = 22
        static let maxLines = 3

        static var labelX: CGFloat { leadingInset + dotDiameter + gap }
        static var minLabelWidth: CGFloat { minWidth - labelX - trailingInset }
        static var maxLabelWidth: CGFloat { maxWidth - labelX - trailingInset }
    }

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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: Metrics.minHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.marble.cgColor
        container.layer?.cornerRadius = Metrics.cornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.bronze.withAlphaComponent(0.4).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.dotDiameter / 2
        container.addSubview(dot)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.basalt
        // A long failure message has to wrap rather than be cut off — it is
        // the one string that points the user at their recovered text.
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = Metrics.maxLines
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        container.addSubview(label)

        self.container = container
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

        present(caption: caption(for: state), color: color(for: state))

        if case .failed = state {
            scheduleAutoHide()
        }
    }

    /// Shows a message that is not an engine state — today, the one the spec
    /// requires when the hotkey is pressed before the Whisper model is ready
    /// ("HUD informa; ditada não inicia"). Without it that press produces no
    /// feedback at all: the keystroke is swallowed by the tap and the only
    /// explanation lives in a menu the user has no reason to open.
    ///
    /// Auto-hides like a failure, because nothing will follow it: no
    /// dictation was started, so no later state change would clear it.
    func notice(_ message: String) {
        autoHideTask?.cancel()
        autoHideTask = nil
        present(caption: message, color: Palette.bronze)
        scheduleAutoHide()
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        window.orderOut(nil)
    }

    private func present(caption: String, color: NSColor) {
        layOut(caption: caption)
        dot.layer?.backgroundColor = color.cgColor
        position()
        window.orderFrontRegardless()
    }

    private func scheduleAutoHide() {
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Sizes the pill around the caption. One-word captions keep the original
    /// 220×44 pill; a message that needs more room gets a wider, taller one
    /// rather than being silently cut in half.
    private func layOut(caption: String) {
        label.stringValue = caption

        let widest = measureLabel(fitting: Metrics.maxLabelWidth)
        let labelWidth = min(max(widest.width.rounded(.up), Metrics.minLabelWidth), Metrics.maxLabelWidth)
        let labelHeight = measureLabel(fitting: labelWidth).height.rounded(.up)

        let pillWidth = labelWidth + Metrics.labelX + Metrics.trailingInset
        let pillHeight = max(Metrics.minHeight, labelHeight + Metrics.verticalPadding * 2)

        window.setContentSize(NSSize(width: pillWidth, height: pillHeight))
        container.frame = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        container.layer?.cornerRadius = min(Metrics.cornerRadius, pillHeight / 2)

        dot.frame = NSRect(x: Metrics.leadingInset,
                           y: (pillHeight - Metrics.dotDiameter) / 2,
                           width: Metrics.dotDiameter,
                           height: Metrics.dotDiameter)
        label.frame = NSRect(x: Metrics.labelX,
                             y: (pillHeight - labelHeight) / 2,
                             width: labelWidth,
                             height: labelHeight)
    }

    private func measureLabel(fitting width: CGFloat) -> NSSize {
        guard let cell = label.cell else { return label.intrinsicContentSize }
        // A finite, absurdly tall bound rather than `.greatestFiniteMagnitude`:
        // the cell multiplies it out internally, and infinities there produce
        // NaN geometry.
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000))
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
        // The payload, not a generic apology. For secure input it reads
        // "Campo de senha em foco. O texto ficou disponível no menu." — the
        // one string that tells the user where their words went, which the
        // spec requires here (§6) and which the discarded version left
        // reachable only from a menu they had no reason to open.
        case .failed(let message): return message
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
