import Foundation

/// One entry in the personal word list.
///
/// `word` is the spelling you want. `soundsLike` holds the things the speech recognizer
/// tends to write instead, for example "stupid designer" for "Stupidesigner".
public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    public var soundsLike: [String]

    public init(id: UUID = UUID(), word: String, soundsLike: [String] = []) {
        self.id = id
        self.word = word
        self.soundsLike = soundsLike
    }
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public var entries: [VocabularyEntry]

    public init(entries: [VocabularyEntry] = []) {
        self.entries = entries
    }

    /// The preferred spellings, without blanks or duplicates.
    public var words: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// Swaps every "sounds like" phrase for its preferred spelling and fixes the capitals
    /// of the word itself ("thumbcheck" becomes "ThumbCheck"). Whole words only.
    public func applyReplacements(to text: String) -> String {
        var pairs: [(alias: String, word: String)] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            pairs.append((word, word))
            for alias in entry.soundsLike {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pairs.append((trimmed, word)) }
            }
        }
        // Longest phrases first, so "mister oops" wins over a shorter overlapping alias.
        pairs.sort { $0.alias.count > $1.alias.count }

        var result = text
        for pair in pairs {
            let pieces = pair.alias.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !pieces.isEmpty else { continue }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + pieces.joined(separator: "[\\s\\-]+") + "(?![\\p{L}\\p{N}])"
            let template = NSRegularExpression.escapedTemplate(for: pair.word)
            result = result.replacingRegex(pattern, with: template)
        }
        return result
    }

    /// The list a fresh install starts with.
    public static let starter = Vocabulary(entries: [
        VocabularyEntry(word: "Stupidesigner", soundsLike: ["stupid designer", "stupid e signer", "stupidesigner"]),
        VocabularyEntry(word: "StupidTalk", soundsLike: ["stupid talk"]),
        VocabularyEntry(word: "Mr. Oops", soundsLike: ["mister oops", "mr oops", "mister oups", "mister ups"])
    ])
}
