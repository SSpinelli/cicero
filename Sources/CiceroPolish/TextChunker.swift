import Foundation

/// Splits a transcript into pieces that fit the on-device model's context
/// window, cutting only at sentence boundaries so the model never sees half a
/// thought.
public enum TextChunker {

    public static func chunk(_ text: String, maxCharacters: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxCharacters else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: trimmed) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxCharacters {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A sentence keeps its terminating punctuation. A trailing fragment with
    /// no terminator is still returned, so nothing is dropped.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
