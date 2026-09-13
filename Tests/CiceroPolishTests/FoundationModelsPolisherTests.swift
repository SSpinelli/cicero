import Testing
import CiceroKit
@testable import CiceroPolish

extension Tag {
    @Tag static var requiresAppleIntelligence: Tag
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
