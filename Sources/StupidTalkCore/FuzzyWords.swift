import Foundation

extension Vocabulary {
    /// Fixes near misses of words on your list that the speech model got almost right:
    /// "stupid dark" becomes "StupidTalk", "stupid designer" becomes "Stupidesigner".
    ///
    /// Up to three spoken words are glued together and compared with each word on the list,
    /// by spelling (edit distance) and by sound (Soundex). The idea comes from the Handy app
    /// (MIT). It is stricter here on purpose: a wrong "fix" is worse than none, so only close
    /// misses change, and only list words of five letters or more are used.
    public func applyFuzzyCorrections(to text: String) -> String {
        let targets = fuzzyTargets
        guard !targets.isEmpty, !text.isEmpty else { return text }

        let tokens = FuzzyToken.scan(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var index = 0
        while index < tokens.count {
            var best: (length: Int, score: Double, word: String)?
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let group = Array(tokens[index..<(index + length)])
                guard FuzzyToken.canJoin(group, in: text) else { continue }
                let key = group.map(\.key).joined()
                guard key.count >= 4 else { continue }
                for target in targets {
                    guard let score = Self.matchScore(spoken: key, target: target.key, words: length) else { continue }
                    if best == nil || score < best!.score || (score == best!.score && length > best!.length) {
                        best = (length, score, target.word)
                    }
                }
            }
            if let best {
                let group = tokens[index..<(index + best.length)]
                let first = group.first!
                let last = group.last!
                let replacement = first.leading + best.word + last.trailing
                let original = String(text[first.range.lowerBound..<last.range.upperBound])
                if replacement != original {
                    replacements.append((first.range.lowerBound..<last.range.upperBound, replacement))
                }
                index += best.length
            } else {
                index += 1
            }
        }

        guard !replacements.isEmpty else { return text }
        var result = text
        for item in replacements.reversed() {
            result.replaceSubrange(item.range, with: item.text)
        }
        return result
    }

    /// Words on the list that are safe to match loosely.
    var fuzzyTargets: [(word: String, key: String)] {
        words.compactMap { word in
            // Plain words only. "C++ (fast)" or "$100" are left to the exact "sounds like" list.
            let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " .-'"))
            guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            let key = FuzzyToken.key(word)
            guard key.count >= 5, key.allSatisfy(\.isASCII) else { return nil }
            return (word, key)
        }
    }

    /// Lower is a closer match. nil when the two are not close enough to swap.
    static func matchScore(spoken: String, target: String, words: Int) -> Double? {
        if spoken == target {
            // Only the spacing or capitals differ, for example "thumb check" for "ThumbCheck".
            return 0
        }
        let longest = max(spoken.count, target.count)
        let limit = max(1, Int((Double(longest) * 0.22).rounded(.down)))
        let distance = Words.editDistance(spoken, target, limit: limit)
        guard distance <= limit else { return nil }
        let ratio = Double(distance) / Double(longest)
        // Close in spelling.
        if ratio <= 0.1 { return ratio }
        // A little further off: only when it is the same length (give or take a letter) and
        // clearly the same sound. That keeps "stupid designers" (people) from becoming the brand.
        guard abs(spoken.count - target.count) <= 1, ratio <= 0.22 else { return nil }
        let soundsAlike = spoken.first == target.first && Soundex.code(spoken) == Soundex.code(target)
        return soundsAlike ? ratio : nil
    }
}

/// One word of the transcript, with the punctuation around it kept aside.
struct FuzzyToken {
    let range: Range<String.Index>
    let leading: String
    let trailing: String
    /// Lowercase letters and digits only.
    let key: String

    static func scan(_ text: String) -> [FuzzyToken] {
        var tokens: [FuzzyToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let raw = text[index..<end]
            let core = raw.drop(while: { !$0.isLetter && !$0.isNumber })
            let leading = String(raw[raw.startIndex..<core.startIndex])
            var coreEnd = core.endIndex
            while coreEnd > core.startIndex {
                let before = core.index(before: coreEnd)
                if core[before].isLetter || core[before].isNumber { break }
                coreEnd = before
            }
            let trailing = String(core[coreEnd..<core.endIndex])
            let word = core[core.startIndex..<coreEnd]
            if !word.isEmpty {
                tokens.append(FuzzyToken(range: index..<end, leading: leading, trailing: trailing, key: key(String(word))))
            }
            index = end
        }
        return tokens
    }

    static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Words can be glued together only when nothing but spaces sits between them:
    /// no line break, no comma or full stop, no bracket.
    static func canJoin(_ group: [FuzzyToken], in text: String) -> Bool {
        guard group.count > 1 else { return true }
        for (position, token) in group.enumerated() {
            if position > 0, !token.leading.isEmpty { return false }
            if position < group.count - 1 {
                if !token.trailing.isEmpty { return false }
                let gap = text[token.range.upperBound..<group[position + 1].range.lowerBound]
                if gap.contains(where: { $0.isNewline }) { return false }
            }
        }
        return true
    }
}

/// American Soundex: a word turned into its first letter and three digits for how it sounds.
enum Soundex {
    static func code(_ word: String) -> String {
        let letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased()
        var previous = digit(for: first)
        for letter in letters.dropFirst() {
            let current = digit(for: letter)
            if let current, current != previous {
                result.append(current)
                if result.count == 4 { break }
            }
            // H and W do not separate two letters with the same digit. Vowels do.
            if letter != "h" && letter != "w" {
                previous = current
            }
        }
        while result.count < 4 { result.append("0") }
        return result
    }

    private static func digit(for letter: Character) -> Character? {
        switch letter {
        case "b", "f", "p", "v": return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t": return "3"
        case "l": return "4"
        case "m", "n": return "5"
        case "r": return "6"
        default: return nil
        }
    }
}
