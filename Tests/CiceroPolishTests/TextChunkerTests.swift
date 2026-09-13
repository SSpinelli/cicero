import Testing
@testable import CiceroPolish

@Suite("TextChunker")
struct TextChunkerTests {

    @Test("short text stays as one chunk")
    func shortTextIsOneChunk() {
        #expect(TextChunker.chunk("Uma frase curta.", maxCharacters: 100) == ["Uma frase curta."])
    }

    @Test("empty text produces no chunks")
    func emptyProducesNothing() {
        #expect(TextChunker.chunk("   ", maxCharacters: 100).isEmpty)
    }

    @Test("splits on sentence boundaries, never mid-sentence")
    func splitsOnSentenceBoundaries() {
        let text = "Primeira frase aqui. Segunda frase aqui. Terceira frase aqui."
        let chunks = TextChunker.chunk(text, maxCharacters: 40)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.hasSuffix("."))
        }
    }

    @Test("every chunk stays within the limit when sentences allow it")
    func respectsLimit() {
        let text = String(repeating: "Uma frase de teste. ", count: 30)
        for chunk in TextChunker.chunk(text, maxCharacters: 100) {
            #expect(chunk.count <= 100)
        }
    }

    @Test("no content is lost")
    func losesNoWords() {
        let text = "Alfa bravo. Charlie delta. Echo foxtrot."
        let rejoined = TextChunker.chunk(text, maxCharacters: 20).joined(separator: " ")
        #expect(rejoined == text)
    }

    @Test("a single sentence longer than the limit is kept whole")
    func oversizedSentenceSurvives() {
        let sentence = String(repeating: "palavra ", count: 50) + "fim."
        let chunks = TextChunker.chunk(sentence, maxCharacters: 50)
        #expect(chunks.count == 1)
        #expect(chunks[0] == sentence.trimmingCharacters(in: .whitespaces))
    }
}
