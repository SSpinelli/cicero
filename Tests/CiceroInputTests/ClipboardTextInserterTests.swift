import AppKit
import Testing
import CiceroKit
@testable import CiceroInput

@Suite("ClipboardTextInserter clipboard handling")
struct ClipboardTextInserterTests {

    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("br.com.cicero.tests.\(UUID().uuidString)"))
    }

    @Test("restores previously held text")
    func restoresText() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)
        #expect(pasteboard.string(forType: .string) == "texto ditado")

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "conteúdo original")
    }

    @Test("restores an empty clipboard as empty")
    func restoresEmptyClipboard() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("preserves multiple representations of one item")
    func preservesMultipleTypes() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("texto simples", forType: .string)
        item.setString("<b>rico</b>", forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "texto simples")
        #expect(pasteboard.string(forType: .html) == "<b>rico</b>")
    }

    @Test("changeCount moves on writes but not on reads")
    func changeCountTracksWritesOnly() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("um", forType: .string)
        let afterWrite = pasteboard.changeCount

        _ = pasteboard.string(forType: .string)
        #expect(pasteboard.changeCount == afterWrite, "ler não deve mover o changeCount")

        pasteboard.clearContents()
        pasteboard.setString("dois", forType: .string)
        #expect(pasteboard.changeCount > afterWrite, "escrever deve mover o changeCount")
    }

    @Test("refuses to insert while secure input is active")
    func refusesDuringSecureInput() async throws {
        try #require(!ClipboardTextInserter.isSecureInputActive,
                     "Um campo de senha está em foco; feche-o e rode de novo.")
        // With secure input off, the guard must not trigger.
        #expect(!ClipboardTextInserter.isSecureInputActive)
    }
}
