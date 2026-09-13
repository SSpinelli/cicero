import AppKit
import Carbon.HIToolbox
import CiceroKit
import Foundation

/// Inserts text into the frontmost app by briefly borrowing the clipboard and
/// posting a synthetic ⌘V.
///
/// Accessibility text insertion would avoid touching the clipboard, but many
/// apps (Electron-based ones especially) do not support it. This works
/// everywhere, at the cost of restoring the clipboard afterwards.
public struct ClipboardTextInserter: TextInserter {

    /// One pasteboard item captured with all of its representations.
    public struct Item: Sendable {
        let contents: [(type: String, data: Data)]
    }

    private let restoreDelay: Duration

    public init(restoreDelay: Duration = .milliseconds(180)) {
        self.restoreDelay = restoreDelay
    }

    /// True when a password field holds focus. macOS blocks synthetic key
    /// events in that state, so pasting would silently do nothing.
    public static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    public func insert(_ text: String) async throws {
        guard !Self.isSecureInputActive else {
            throw CiceroError.insertionBlockedBySecureInput
        }

        let pasteboard = NSPasteboard.general
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
            try Self.postPasteShortcut()
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

    private static func postPasteShortcut() throws {
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
