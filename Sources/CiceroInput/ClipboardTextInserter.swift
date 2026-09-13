import AppKit
import Carbon.HIToolbox
import CiceroKit
import Foundation

/// Confines the `NSPasteboard` concurrency assertion to a type we own.
///
/// `NSPasteboard` predates strict-concurrency auditing and is not `Sendable`,
/// yet handing one to `ClipboardTextInserter` means crossing into an actor.
/// A `@retroactive Sendable` conformance on `NSPasteboard` itself would have
/// been module-wide and *exported*: every importer of `CiceroInput` would
/// silently lose the compiler's data-race diagnostic for a system type we do
/// not own, and a future SDK declaring that conformance would turn this into
/// a hard build error. A wrapper asserts the same thing about one type we do
/// own, and exports nothing.
///
/// What makes the assertion hold here: access is serialised by
/// `ClipboardTextInserter`'s FIFO mutex and ordered by its awaits.
/// `NSPasteboard` itself is not documented as thread-safe, so concurrent use
/// from several isolation domains would not be covered by this.
struct PasteboardHandle: @unchecked Sendable {
    let pasteboard: NSPasteboard
}

/// Inserts text into the frontmost app by briefly borrowing the clipboard and
/// posting a synthetic ⌘V.
///
/// Accessibility text insertion would avoid touching the clipboard, but many
/// apps (Electron-based ones especially) do not support it. This works
/// everywhere, at the cost of restoring the clipboard afterwards.
///
/// `insert` serializes concurrent callers with an explicit async mutex
/// (`acquire`/`release`), not just by being an actor. Actors are reentrant
/// across suspension points, and the `Task.sleep` inside `insert` is exactly
/// such a point: without the mutex, a second `insert` call arriving during
/// the first's sleep would take its "original clipboard" snapshot *after*
/// the first call had already overwritten the pasteboard with its own
/// dictated text, and would later durably restore that stale text instead of
/// the user's real content — corrupting the clipboard permanently. The mutex
/// makes each `insert` call run to completion (through its own
/// restore-or-skip decision) before the next one so much as reads the
/// pasteboard, so calls queue instead of overlapping.
public actor ClipboardTextInserter: TextInserter {

    /// One pasteboard item captured with all of its representations.
    public struct Item: Sendable {
        let contents: [(type: String, data: Data)]
    }

    private let restoreDelay: Duration
    private let handle: PasteboardHandle
    private let pasteStep: PasteStep
    private let secureInputCheck: @Sendable () -> Bool

    // FIFO async mutex guarding the body of `insert`. `isBusy`/`waiters` are
    // actor-isolated, so checking and updating them never races with another
    // `insert` call doing the same — see the type-level doc comment for why
    // this is necessary in addition to actor isolation.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(restoreDelay: Duration = .milliseconds(180)) {
        self.init(restoreDelay: restoreDelay,
                  pasteboard: PasteboardHandle(pasteboard: .general),
                  pasteStep: SystemPasteStep(),
                  secureInputCheck: { ClipboardTextInserter.isSecureInputActive })
    }

    /// Test seam: lets tests target a scratch pasteboard, substitute a fake
    /// paste step that never posts real key events, and force the
    /// secure-input branch without depending on real system state.
    init(restoreDelay: Duration,
         pasteboard: PasteboardHandle,
         pasteStep: PasteStep,
         secureInputCheck: @escaping @Sendable () -> Bool = { ClipboardTextInserter.isSecureInputActive }) {
        self.restoreDelay = restoreDelay
        self.handle = pasteboard
        self.pasteStep = pasteStep
        self.secureInputCheck = secureInputCheck
    }

    /// True when a password field holds focus. macOS blocks synthetic key
    /// events in that state, so pasting would silently do nothing.
    public static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    public func insert(_ text: String) async throws {
        await acquire()
        defer { release() }

        guard !secureInputCheck() else {
            throw CiceroError.insertionBlockedBySecureInput
        }

        let pasteboard = handle.pasteboard
        let snapshot = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Self.restore(snapshot, to: pasteboard)
            throw CiceroError.insertionFailed("não foi possível escrever na área de transferência")
        }

        // Remember what the pasteboard looked like right after our own write,
        // so we can tell later whether anyone else touched it.
        let ourChangeCount = pasteboard.changeCount

        do {
            try await pasteStep.perform()
        } catch {
            Self.restore(snapshot, to: pasteboard)
            throw error
        }

        // There is no way to observe the target app *reading* the pasteboard —
        // changeCount moves on writes, never on reads — so the wait is a
        // calibrated delay rather than a confirmation.
        try? await Task.sleep(for: restoreDelay)

        // If another process wrote to the clipboard while we waited, its
        // content is newer than ours; restoring would destroy it. This check
        // and the restore that follows it are both synchronous — no
        // suspension point between them — so the decision can't go stale.
        guard pasteboard.changeCount == ourChangeCount else { return }
        Self.restore(snapshot, to: pasteboard)
    }

    public static func snapshot(of pasteboard: NSPasteboard) -> [Item] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Item(contents: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type.rawValue, data: data)
            })
        }
    }

    public static func restore(_ items: [Item], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for entry in item.contents {
                pasteboardItem.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restored)
    }

    /// Suspends the caller until it is this call's turn. The first caller of
    /// an idle inserter proceeds immediately; anyone calling while the lock
    /// is held is queued and resumed in arrival order once `release()` hands
    /// them the turn.
    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands the turn to the next queued caller, if any; otherwise marks the
    /// inserter idle again. Always runs — success or failure — via `defer`
    /// in `insert`, so a thrown error can never leave the lock stuck held.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Seam for the synthetic ⌘V step, so `insert`'s orchestration — guard
/// ordering, the changeCount capture point, which branch restores versus
/// rethrows — can be driven and asserted on in tests without posting real
/// key events into the session.
protocol PasteStep: Sendable {
    func perform() async throws
}

/// The real paste step: posts a synthetic ⌘V via Core Graphics events.
struct SystemPasteStep: PasteStep {
    func perform() async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw CiceroError.insertionFailed("não foi possível criar a fonte de eventos")
        }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else {
            throw CiceroError.insertionFailed("não foi possível criar o evento de teclado")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
