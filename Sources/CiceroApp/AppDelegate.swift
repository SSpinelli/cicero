import AppKit
import CiceroAudio
import CiceroInput
import CiceroKit
import CiceroPolish
import CiceroWhisper

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var engine: DictationEngine?
    private var hotkeyMonitor: HotkeyMonitor?
    /// Pinned to Portuguese rather than auto-detected. The spec asked for
    /// auto-detection so mixed pt/en dictation would work, but measurement
    /// showed that choice is not viable at this clip length: on the same
    /// two-second recording, auto-detection returned an English paraphrase
    /// five times out of five, while `pt` returned the exact sentence three
    /// times out of three. English words inside Portuguese speech still
    /// transcribe fine with the language pinned; a wrong language token does
    /// not.
    private let transcriber = WhisperKitTranscriber(language: "pt")

    /// Where the Whisper model is in its load.
    ///
    /// Deliberately not a plain `Bool`: a menu bar app has nowhere but this
    /// menu to say what went wrong, so `statusLine` needs to distinguish
    /// "still loading" from "failed" rather than collapsing both to
    /// "not ready yet". A load failure here is not permanent —
    /// `WhisperKitTranscriber.prepare()` clears its in-flight task on
    /// failure specifically so a later call starts a fresh attempt (see its
    /// doc comment) — so `.failed` is paired with a "Tentar novamente" menu
    /// item rather than being a dead end.
    private enum ModelLoadState {
        case loading
        case ready
        case failed(String)
    }
    private var modelLoadState: ModelLoadState = .loading

    /// Whether `hotkeyMonitor.start()` has actually installed its event tap.
    ///
    /// Tracked separately from `modelLoadState` because the two failure modes
    /// are independent and both common on a first run: `start()` throws
    /// `CiceroError.accessibilityNotGranted` until the user grants
    /// Accessibility, which routinely happens *after* the model has already
    /// finished loading. Without this flag, `statusLine` would read "Pronto —
    /// segure ⌃⌥Espaço" the moment the model is ready even though no event
    /// tap exists yet, and a press would do nothing with no indication why.
    ///
    /// Retried from two places while `false`: `applicationDidBecomeActive`
    /// (fires when activation happens to occur, which is not guaranteed for
    /// a Dock-less, window-less accessory app) and `menuNeedsUpdate` (fires
    /// every time the user opens the menu, which — since the menu is the
    /// only place this state is visible — is guaranteed to happen if the
    /// user is checking on it at all). The second one is what actually makes
    /// "grant Accessibility, come back" reliable.
    private var hotkeyArmed = false

    /// The most recently enqueued hotkey-triggered engine call, so the next
    /// one can wait for it before running.
    ///
    /// `HotkeyMonitor.onPress`/`onRelease` each fire synchronously on the
    /// main actor and spawn an unstructured `Task` to call into the engine.
    /// Swift does not guarantee two unstructured tasks created in order
    /// press-then-release actually run in that order (the same hazard
    /// `MicrophoneRecorder`'s consumer task documents) — on a very fast tap,
    /// the release's task could run first, see `engine.state == .idle`,
    /// no-op, and strand the engine recording forever with no further
    /// release to stop it. Chaining each new task after the previous one
    /// restores press-before-release ordering without blocking the
    /// synchronous callback itself.
    private var actionTask: Task<Void, Never>?

    private let hud = HUDWindow()
    private let recorder = MicrophoneRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherInstanceIsRunning() else { return }
        setUpStatusItem()
        buildEngine()
        Task { await requestPermissionsAndStart() }
        Task { await loadModel() }
    }

    /// Quits immediately if Cicero is already running, and says so in the log.
    ///
    /// A second copy is not merely redundant here, it is actively harmful: two
    /// identical laurel glyphs appear in the menu bar with nothing to tell them
    /// apart, two event taps compete for the same hotkey so which one answers
    /// is arbitrary, and two ~1.5 GB models sit in memory at once. This cost a
    /// full debugging session — a stale build and a fresh one ran side by side,
    /// the stale one answered the hotkey, and its behaviour was attributed to
    /// the fresh one for some time.
    ///
    /// Matching is by bundle identifier, so this also catches the case that
    /// caused that confusion: the same app launched from two different paths,
    /// such as a development build alongside an installed one.
    private func anotherInstanceIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }

        ciceroLog.notice("encerrando: o Cicero já está em execução (pid \(existing.processIdentifier))")
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    /// A best-effort retry point, not the guaranteed one: activation of an
    /// accessory app with no Dock icon and no windows is not reliably
    /// triggered by opening its status item's menu, so this can simply never
    /// fire on some systems. `menuNeedsUpdate` below is the retry that
    /// actually has to work; this one is free insurance for the cases where
    /// activation does happen. `HotkeyMonitor.start()` is idempotent once
    /// armed (`guard tap == nil else { return }`), so retrying costs nothing
    /// when it's already running.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !hotkeyArmed else { return }
        startHotkeyMonitor(showAlertOnFailure: false)
    }

    // MARK: - Composition

    private func buildEngine() {
        // Held concretely rather than as `any AudioRecorder` so the HUD can
        // draw the voice: `levels` is deliberately off the port, since the
        // dictation engine has no use for it and widening the port would make
        // every future recorder carry it for one view's benefit.
        hud.drawVoice(from: recorder.levels)

        // The polisher is chosen once at launch: Apple's on-device model when
        // available, otherwise raw text still reaches the user.
        // Written as if/else rather than a ternary because the two branches
        // have different concrete types.
        let polisher: any TextPolisher
        if FoundationModelsPolisher.isAvailable {
            polisher = FoundationModelsPolisher()
        } else {
            polisher = PassthroughPolisher()
        }

        let engine = DictationEngine(
            recorder: recorder,
            transcriber: transcriber,
            polisher: polisher,
            inserter: ClipboardTextInserter(),
            contextProvider: WorkspaceContextProvider())
        self.engine = engine

        hotkeyMonitor = HotkeyMonitor(
            hotkey: .defaultHotkey,
            onPress: { [weak self] in
                guard let self else { return }
                // Spec §6: "Modelo Whisper ainda não baixado → HUD informa;
                // ditada não inicia." Dropping the press silently is not that:
                // the tap has already swallowed the keystroke, so without this
                // the user sees their Space vanish and gets no explanation
                // anywhere except a menu they have no reason to open.
                switch self.modelLoadState {
                case .loading:
                    self.hud.notice("Carregando modelo… aguarde para ditar")
                    return
                case .failed(let message):
                    self.hud.notice(message)
                    return
                case .ready:
                    break
                }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    await self.engine?.startDictation()
                    self.syncHUD()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    // Unstructured, not linked to this task's own
                    // cancellation via `withTaskCancellationHandler` or
                    // similar: nothing in this file ever cancels
                    // `actionTask`, and `finishDictation()` below cannot
                    // throw (see its doc comment), so today the ticker is
                    // always reached and cancelled by the line below. If a
                    // future teardown-on-quit hook starts cancelling
                    // `actionTask`, that cancellation would not propagate to
                    // `ticker` — it would keep polling until
                    // `finishDictation()` itself returns rather than
                    // stopping immediately.
                    let ticker = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            self?.syncHUD()
                            try? await Task.sleep(for: .milliseconds(120))
                        }
                    }
                    await self.engine?.finishDictation()
                    ticker.cancel()
                    self.syncHUD()
                }
            },
            // Spec §4.3's `recording --Esc--> idle`. Chained onto the same
            // `actionTask` as press and release for the same reason they are:
            // a cancel that ran before the press it belongs to would find the
            // engine `.idle`, no-op, and leave the dictation running.
            onCancel: { [weak self] in
                guard let self else { return }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    await self.engine?.cancelDictation()
                    self.syncHUD()
                }
            })
    }

    private func requestPermissionsAndStart() async {
        if Permissions.microphoneStatus == .notDetermined {
            _ = await Permissions.requestMicrophone()
        } else if Permissions.microphoneStatus == .denied {
            presentAlert(title: "Permissão de microfone necessária",
                         message: "O Cicero precisa do microfone para ouvir o ditado.",
                         pane: .microphone)
        }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        startHotkeyMonitor(showAlertOnFailure: true)
    }

    /// Attempts to arm the global hotkey tap. Called once at launch (with an
    /// alert on failure — this is the one alert the whole first run depends
    /// on) and again, silently, from `applicationDidBecomeActive` and
    /// `menuNeedsUpdate` every time either fires while still unarmed
    /// (repeating the alert on every reactivation or menu open would be
    /// obnoxious, and the status line already keeps saying the hotkey is
    /// inactive).
    ///
    /// Requires an actual `HotkeyMonitor` to declare success: `try
    /// hotkeyMonitor?.start()` alone would not throw when `hotkeyMonitor` is
    /// `nil` (only reachable if this ran before `buildEngine()`, which the
    /// normal launch sequence never does — but `hotkeyArmed`'s only job is
    /// to not lie about the tap, so it must not have a path that does).
    private func startHotkeyMonitor(showAlertOnFailure: Bool) {
        guard let hotkeyMonitor else { return }
        do {
            try hotkeyMonitor.start()
            hotkeyArmed = true
        } catch {
            hotkeyArmed = false
            guard showAlertOnFailure else { return }
            presentAlert(title: "Permissão de Acessibilidade necessária",
                         message: "O Cicero precisa dela para ouvir o atalho global e colar o texto.",
                         pane: .accessibility)
        }
    }

    private func loadModel() async {
        do {
            try await transcriber.prepare()
            modelLoadState = .ready
        } catch {
            let message = (error as? CiceroError)?.userMessage ?? error.localizedDescription
            modelLoadState = .failed(message)
            presentAlert(title: "Não foi possível carregar o modelo",
                         message: message,
                         pane: nil)
        }
    }

    @objc private func retryModelLoad() {
        modelLoadState = .loading
        Task { await loadModel() }
    }

    // MARK: - HUD

    /// The menu refreshes itself via `menuNeedsUpdate(_:)`, so only the HUD
    /// needs pushing.
    private func syncHUD() {
        guard let state = engine?.state else { return }
        switch state {
        case .idle:
            hud.hide()
        default:
            hud.show(state: state)
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.image?.accessibilityDescription = "Cicero"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilds the menu's contents just before AppKit displays it, so it
    /// always renders whatever is true at that instant instead of a snapshot
    /// from whenever the last engine call happened to finish. This also
    /// means the menu is never reassigned out from under itself while the
    /// user might have it open — only its items change.
    ///
    /// Also the guaranteed retry point for arming the hotkey: a menu bar
    /// extra's own menu opening does not reliably activate the owning app
    /// (`applicationDidBecomeActive` is a best-effort backstop, not a
    /// guarantee — see `hotkeyArmed`'s doc comment), but the user opening
    /// this menu to check the status is guaranteed, since it's the only
    /// place that status is visible. Retrying here — silently, since a
    /// dropdown appearing is not the moment for a modal alert — is what
    /// actually makes "grant Accessibility, come back" work every time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if !hotkeyArmed {
            startHotkeyMonitor(showAlertOnFailure: false)
        }

        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if case .failed = modelLoadState {
            let retry = NSMenuItem(title: "Tentar novamente", action: #selector(retryModelLoad), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
            menu.addItem(.separator())
        }

        if let transcript = engine?.lastTranscript, !transcript.isEmpty {
            let item = NSMenuItem(title: "Copiar última transcrição",
                                  action: #selector(copyLastTranscript),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let preview = NSMenuItem(title: String(transcript.prefix(60)), action: nil, keyEquivalent: "")
            preview.isEnabled = false
            menu.addItem(preview)
            menu.addItem(.separator())
        }

        let about = NSMenuItem(title: "Cicero — \(Palette.tagline)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusLine: String {
        switch modelLoadState {
        case .loading:
            return "Carregando modelo…"
        case .failed(let message):
            return message
        case .ready:
            guard hotkeyArmed else {
                return "Atalho inativo — conceda Acessibilidade e volte ao Cicero"
            }
            switch engine?.state ?? .idle {
            case .idle:         return "Pronto — segure ⌃⌥Espaço"
            case .recording:    return "Ouvindo…"
            case .transcribing: return "Transcrevendo…"
            case .polishing:    return "Polindo…"
            case .inserting:    return "Inserindo…"
            case .failed(let message): return message
            }
        }
    }

    @objc private func copyLastTranscript() {
        guard let transcript = engine?.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func presentAlert(title: String, message: String, pane: Permissions.SettingsPane?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if pane != nil { alert.addButton(withTitle: "Abrir Ajustes") }
        alert.addButton(withTitle: "Fechar")
        // Cicero is an accessory app with no Dock icon and no window: without
        // explicitly activating, `runModal()` can present this alert behind
        // whatever app is frontmost, where the user may never see it — and
        // for the accessibility alert this is the one message the entire
        // first run depends on.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let pane {
            Permissions.openSettings(pane)
        }
    }
}
