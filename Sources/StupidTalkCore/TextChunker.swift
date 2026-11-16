import Foundation

/// Splits a long dictation into pieces the on-device model can handle one at a time.
public enum TextChunker {
    public static func chunks(_ text: String, maxWords: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maxWords > 0, Words.count(trimmed) > maxWords else { return [trimmed] }

        var pieces: [String] = []
        var current = ""
        var currentWords = 0

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
            currentWords = 0
        }

        for sentence in sentences(in: trimmed) {
            let words = Words.count(sentence)
            if words > maxWords {
                // One endless sentence. Cut it by word count.
                flush()
                pieces.append(contentsOf: hardSplit(sentence, maxWords: maxWords))
                continue
            }
            if currentWords + words > maxWords { flush() }
            if !current.isEmpty { current += " " }
            current += sentence
            currentWords += words
        }
        flush()
        return pieces
    }

    /// Sentences end at ". ", "! ", "? " or a line break.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?

        func push() {
            let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            current = ""
        }

        for character in text {
            if character == "\n" {
                push()
            } else if character.isWhitespace, let last = previous, last == "." || last == "!" || last == "?" {
                push()
            } else {
                current.append(character)
            }
            previous = character
        }
        push()
        return result
    }

    static func hardSplit(_ sentence: String, maxWords: Int) -> [String] {
        let words = sentence.split(whereSeparator: { $0.isWhitespace })
        var result: [String] = []
        var index = 0
        while index < words.count {
            let end = Swift.min(index + maxWords, words.count)
            result.append(words[index..<end].joined(separator: " "))
            index = end
        }
        return result
    }
}
