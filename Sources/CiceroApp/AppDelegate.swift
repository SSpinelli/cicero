import AppKit
import CiceroAudio
import CiceroInput
import CiceroKit
import CiceroPolish
import CiceroWhisper
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var engine: DictationEngine?
    private var hotkeyMonitor: HotkeyMonitor?
    private let transcriber = WhisperKitTranscriber()

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        buildEngine()
        Task { await requestPermissionsAndStart() }
        Task { await loadModel() }
    }

    /// Accessory apps still receive this when the user interacts with the
    /// status item (clicking it briefly activates the process). It's the
    /// natural point to retry arming the hotkey: the common sequence is
    /// press hotkey → nothing happens → open the menu (which activates us)
    /// → grant Accessibility in the Settings pane the alert opened → click
    /// back into Cicero. `HotkeyMonitor.start()` is idempotent once armed
    /// (`guard tap == nil else { return }`), so retrying costs nothing when
    /// it's already running.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !hotkeyArmed else { return }
        startHotkeyMonitor(showAlertOnFailure: false)
    }

    // MARK: - Composition

    private func buildEngine() {
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
            recorder: MicrophoneRecorder(),
            transcriber: transcriber,
            polisher: polisher,
            inserter: ClipboardTextInserter(),
            contextProvider: WorkspaceContextProvider())
        self.engine = engine

        hotkeyMonitor = HotkeyMonitor(
            hotkey: .defaultHotkey,
            onPress: { [weak self] in
                guard let self, case .ready = self.modelLoadState else { return }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    await self.engine?.startDictation()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    await self.engine?.finishDictation()
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
    /// on) and again from `applicationDidBecomeActive` every time the app is
    /// reactivated while still unarmed (silently — repeating the alert on
    /// every click into the status item would be obnoxious, and the status
    /// line already keeps saying the hotkey is inactive).
    private func startHotkeyMonitor(showAlertOnFailure: Bool) {
        do {
            try hotkeyMonitor?.start()
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

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "laurel.leading", accessibilityDescription: "Cicero")
        item.button?.image?.isTemplate = true
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
    func menuNeedsUpdate(_ menu: NSMenu) {
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
