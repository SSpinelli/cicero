import AppKit
import Testing
import CiceroKit
@testable import CiceroInput

@Suite("ClipboardTextInserter clipboard handling")
struct ClipboardTextInserterTests {

    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("br.com.cicero.tests.\(UUID().uuidString)"))
    }

    // MARK: - snapshot / restore, exercised directly

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

    // MARK: - insert(_:), driven through the real orchestration via a fake paste step

    @Test("refuses to insert while secure input is active, leaving the clipboard untouched")
    func refusesDuringSecureInput() async throws {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let inserter = ClipboardTextInserter(
            restoreDelay: .milliseconds(10),
            pasteboard: pasteboard,
            pasteStep: FakePasteStep(pasteboard: pasteboard),
            secureInputCheck: { true }
        )

        do {
            try await inserter.insert("texto ditado")
            Issue.record("esperava que insert lançasse insertionBlockedBySecureInput")
        } catch let error as CiceroError {
            #expect(error == .insertionBlockedBySecureInput)
        } catch {
            Issue.record("erro inesperado: \(error)")
        }

        #expect(pasteboard.string(forType: .string) == "conteúdo original")
    }

    @Test("restores the clipboard and rethrows when the paste step fails")
    func failingPasteStepRestoresAndRethrows() async throws {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let pasteStep = FakePasteStep(pasteboard: pasteboard, errorToThrow: .insertionFailed("falha simulada no colar"))

        let inserter = ClipboardTextInserter(
            restoreDelay: .milliseconds(10),
            pasteboard: pasteboard,
            pasteStep: pasteStep,
            secureInputCheck: { false }
        )

        do {
            try await inserter.insert("texto ditado")
            Issue.record("esperava que insert relançasse o erro do paste step")
        } catch let error as CiceroError {
            #expect(error == .insertionFailed("falha simulada no colar"))
        } catch {
            Issue.record("erro inesperado: \(error)")
        }

        #expect(pasteboard.string(forType: .string) == "conteúdo original")
    }

    @Test("writes the dictated text before pasting, then restores the original")
    func happyPathWritesThenRestores() async throws {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let pasteStep = FakePasteStep(pasteboard: pasteboard)

        let inserter = ClipboardTextInserter(
            restoreDelay: .milliseconds(10),
            pasteboard: pasteboard,
            pasteStep: pasteStep,
            secureInputCheck: { false }
        )

        try await inserter.insert("texto ditado")

        #expect(pasteStep.observedText == "texto ditado")
        #expect(pasteboard.string(forType: .string) == "conteúdo original")
    }

    @Test("two overlapping insert calls queue instead of overlapping, so the original survives")
    func concurrentInsertsDoNotCorruptTheClipboard() async throws {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let inserter = ClipboardTextInserter(
            restoreDelay: .milliseconds(30),
            pasteboard: pasteboard,
            pasteStep: FakePasteStep(pasteboard: pasteboard),
            secureInputCheck: { false }
        )

        async let first: () = inserter.insert("primeiro ditado")
        async let second: () = inserter.insert("segundo ditado")
        _ = try await (first, second)

        let finalValue = pasteboard.string(forType: .string)
        #expect(finalValue == "conteúdo original")
        #expect(finalValue != "primeiro ditado")
        #expect(finalValue != "segundo ditado")
    }
}

/// A test double for the synthetic ⌘V step. Records what the pasteboard held
/// the instant it "pasted," and can be told to fail instead — this drives
/// `insert`'s real orchestration deterministically without posting real key
/// events or depending on the machine's actual secure-input state.
private final class FakePasteStep: PasteStep, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let errorToThrow: CiceroError?
    private let lock = NSLock()
    private var _observedText: String?

    init(pasteboard: NSPasteboard, errorToThrow: CiceroError? = nil) {
        self.pasteboard = pasteboard
        self.errorToThrow = errorToThrow
    }

    var observedText: String? {
        lock.withLock { _observedText }
    }

    func perform() async throws {
        let text = pasteboard.string(forType: .string)
        lock.withLock { _observedText = text }
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
