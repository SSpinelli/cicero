import AppKit
import CiceroKit

/// A small floating pill near the bottom of the screen showing dictation
/// state. Borderless, non-activating, and never steals focus from the app the
/// user is dictating into.
///
/// The drawing lives in `HUDView`; this type owns the panel, the animation
/// timer, and the rules about when each state is shown.
@MainActor
final class HUDWindow {

    private let window: NSPanel
    private let view: HUDView

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

    /// Drives the wreath opening and closing, and decays the drawn voice when
    /// no new audio arrives. Runs only while the pill is on screen.
    private var animation: Timer?

    /// Feeds `HUDView.levels` from the recorder while a dictation is live.
    private var levelTask: Task<Void, Never>?

    private enum Metrics {
        static let width: CGFloat = 208
        static let height: CGFloat = 44
        static let bottomMargin: CGFloat = 96
        /// Matches `HUDView`'s bar count: fewer readings than bars would leave
        /// a permanently flat stretch on the left.
        static let barCount = 18
    }

    init() {
        // NSPanel, not NSWindow: `.nonactivatingPanel` is a panel-only style
        // mask and is inert on a plain NSWindow. Combined with
        // `becomesKeyOnlyIfNeeded`, this keeps the caret in the app the user
        // is dictating into — showing the HUD must never steal focus.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
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

        view = HUDView(frame: NSRect(x: 0, y: 0,
                                     width: Metrics.width, height: Metrics.height))
        window.contentView = view
    }

    /// Starts drawing the user's voice from `levels`.
    ///
    /// Called once at composition. The stream is single-consumer and lives for
    /// the life of the recorder, delivering readings only while a recording is
    /// running, so this simply stays attached.
    func drawVoice(from levels: AsyncStream<Float>) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                self.append(level: CGFloat(level))
            }
        }
    }

    func show(state: DictationState) {
        autoHideTask?.cancel()
        autoHideTask = nil

        switch state {
        case .recording:
            // No caption and no wreath: the voice is the feedback, and either
            // one here would only compete with it.
            view.caption = nil
            view.accent = Palette.laurelOnDark
            view.tintsCaption = false
            target = 0
        case .transcribing, .polishing, .inserting:
            view.caption = caption(for: state)
            view.accent = Palette.laurelOnDark
            view.tintsCaption = false
            target = 1
        case .failed(let message):
            view.caption = message
            view.accent = Palette.terracotta
            view.tintsCaption = true
            target = 1
            scheduleAutoHide()
        case .idle:
            hide()
            return
        }

        present()
    }

    /// A message shown without a dictation behind it — the model still loading,
    /// a permission missing. Nothing will follow it to clear the pill, so it
    /// dismisses itself.
    func notice(_ message: String) {
        autoHideTask?.cancel()
        view.caption = message
        view.accent = Palette.bronze
        view.tintsCaption = false
        // Half-closed: a notice is the app talking, not the app working.
        target = 0.5
        present()
        scheduleAutoHide()
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        animation?.invalidate()
        animation = nil
        window.orderOut(nil)
    }

    // MARK: - Presentation

    /// Where the wreath is heading. `view.close` eases toward it so the
    /// branches fold rather than snap.
    private var target: CGFloat = 0

    private func present() {
        position()
        window.orderFrontRegardless()
        startAnimating()
    }

    private func startAnimating() {
        guard animation == nil else { return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // Ease the wreath toward its target.
        let delta = target - view.close
        if abs(delta) > 0.005 {
            view.close += delta * 0.18
        }

        // Let the drawn voice fall away when no audio is arriving, so a paused
        // speaker sees the bars settle instead of freezing mid-shout.
        guard view.caption == nil else { return }
        if !levels.isEmpty {
            levels = levels.map { $0 * 0.82 }
            view.levels = levels
        }
    }

    private var levels: [CGFloat] = []

    private func append(level: CGFloat) {
        levels.append(level)
        if levels.count > Metrics.barCount {
            levels.removeFirst(levels.count - Metrics.barCount)
        }
        view.levels = levels
    }

    private func scheduleAutoHide() {
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        window.setFrame(NSRect(x: frame.midX - Metrics.width / 2,
                               y: frame.minY + Metrics.bottomMargin,
                               width: Metrics.width,
                               height: Metrics.height),
                        display: true)
    }

    private func caption(for state: DictationState) -> String {
        switch state {
        case .idle: return "Pronto"
        case .recording: return "Ouvindo"
        case .transcribing: return "Transcrevendo"
        case .polishing: return "Polindo"
        case .inserting: return "Inserindo"
        case .failed(let message): return message
        }
    }
}
