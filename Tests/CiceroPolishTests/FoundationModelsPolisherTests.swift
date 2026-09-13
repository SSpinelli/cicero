import Testing
import Foundation
import CiceroKit
@testable import CiceroPolish

extension Tag {
    @Tag static var requiresAppleIntelligence: Tag
}

/// Lowercased, punctuation-stripped words, so filler checks can't be fooled
/// by a word hiding inside another word or by stray punctuation, and can't
/// false-fail on casing.
private func words(in text: String) -> Set<String> {
    Set(
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
}

@Suite("Polishers")
struct PolisherTests {

    @Test("passthrough returns the text unchanged")
    func passthroughIsIdentity() async throws {
        let polished = try await PassthroughPolisher().polish("texto cru", context: .unknown)
        #expect(polished == "texto cru")
    }

    @Test("reports availability without crashing")
    func availabilityIsQueryable() {
        _ = FoundationModelsPolisher.isAvailable
    }

    @Test("removes filler words and adds punctuation", .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func polishesRealText() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let polisher = FoundationModelsPolisher()
        let raw = "então tipo assim eu queria pedir né uma reunião pra gente falar do projeto amanhã"
        let polished = try await polisher.polish(
            raw,
            context: DictationContext(appName: "Mail", bundleIdentifier: "com.apple.mail"))

        #expect(!polished.isEmpty)
        #expect(polished.lowercased().contains("reunião"))
        #expect(polished.contains(".") || polished.contains(","))

        // The whole point of this polisher is removing verbal filler — a test
        // that only checks length/keyword/punctuation can stay green while
        // "tipo" and "né" survive untouched. Check words, not substrings, so
        // this can't be fooled by a filler hiding inside a legitimate word.
        let polishedWords = words(in: polished)
        #expect(!polishedWords.contains("tipo"), "filler \"tipo\" survived polishing: \"\(polished)\"")
        #expect(!polishedWords.contains("né"), "filler \"né\" survived polishing: \"\(polished)\"")
    }

    // "aí" and "sabe" are common Brazilian Portuguese hesitation markers, but
    // both are also ordinary words with real meaning ("sabe" the verb "to
    // know", "aí" the locative adverb "there"). The golden rule — never lose
    // what the user said — outranks polish quality, so these two must survive
    // when they are doing real grammatical work, not just when they are inert
    // filler syllables.

    @Test(
        "preserves \"sabe\" when it is the verb, not a hesitation tag",
        .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func preservesSabeAsVerb() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let raw = "tipo ele sabe a resposta do exercício"
        let polished = try await FoundationModelsPolisher().polish(raw, context: .unknown)

        let polishedWords = words(in: polished)
        #expect(polishedWords.contains("sabe"), "verb \"sabe\" was lost during polishing: \"\(polished)\"")
        #expect(!polishedWords.contains("tipo"), "filler \"tipo\" survived polishing: \"\(polished)\"")
    }

    @Test(
        "preserves \"aí\" when it is a locative adverb, not a hesitation tag",
        .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func preservesAiAsLocative() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let raw = "tipo coloca aí na mesa"
        let polished = try await FoundationModelsPolisher().polish(raw, context: .unknown)

        let polishedWords = words(in: polished)
        #expect(polishedWords.contains("aí"), "locative \"aí\" was lost during polishing: \"\(polished)\"")
        #expect(!polishedWords.contains("tipo"), "filler \"tipo\" survived polishing: \"\(polished)\"")
    }

    @Test("preserves meaning rather than answering the text", .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func doesNotAnswerTheContent() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let polished = try await FoundationModelsPolisher().polish(
            "qual é a capital da França",
            context: .unknown)
        #expect(!polished.lowercased().contains("paris"))
    }
}
