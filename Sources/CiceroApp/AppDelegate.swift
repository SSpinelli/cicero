import AppKit
import CiceroAudio
import CiceroInput
import CiceroKit
import CiceroPolish
import CiceroWhisper
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var engine: DictationEngine?
    private var hotkeyMonitor: HotkeyMonitor?
    private let transcriber = WhisperKitTranscriber()

    /// Where the Whisper model is in its (uncancellable, single-flight) load.
    /// Deliberately not a plain `Bool`: once a load fails there is no retry
    /// path (see `WhisperKitTranscriber.prepare()`'s doc comment), and a menu
    /// bar app has nowhere but this menu to say so. A `Bool` would make
    /// `statusLine` fall back to "Carregando modelo…" forever after a real
    /// failure, hiding the one thing a user in that state needs to see.
    private enum ModelLoadState {
        case loading
        case ready
        case failed(String)
    }
    private var modelLoadState: ModelLoadState = .loading

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
                    self.refreshStatusItem()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                let previous = self.actionTask
                self.actionTask = Task { @MainActor in
                    await previous?.value
                    await self.engine?.finishDictation()
                    self.refreshStatusItem()
                }
            })
    }

    private func requestPermissionsAndStart() async {
        if Permissions.microphoneStatus == .notDetermined {
            _ = await Permissions.requestMicrophone()
        }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        do {
            try hotkeyMonitor?.start()
        } catch {
            presentAlert(title: "Permissão de Acessibilidade necessária",
                         message: "O Cicero precisa dela para ouvir o atalho global e colar o texto.",
                         pane: .accessibility)
        }
        refreshStatusItem()
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
        refreshStatusItem()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "laurel.leading", accessibilityDescription: "Cicero")
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

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

        statusItem?.menu = menu
    }

    private var statusLine: String {
        switch modelLoadState {
        case .loading:
            return "Carregando modelo…"
        case .failed(let message):
            return message
        case .ready:
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
        if alert.runModal() == .alertFirstButtonReturn, let pane {
            Permissions.openSettings(pane)
        }
    }
}
