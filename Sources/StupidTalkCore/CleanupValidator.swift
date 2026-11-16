import Foundation

public enum CleanupVerdict: Equatable, Sendable {
    /// The model's answer is a believable clean-up of what was said.
    case accepted(String)
    /// The answer was thrown away. The string says why, for the log.
    case rejected(String)
}

/// Safety checks on what the on-device model returns.
///
/// A language model can do the wrong job: answer the question you dictated, write the
/// poem you asked a friend for, summarize, or apologize. A clean-up mostly deletes words
/// and fixes a few, so a good answer is roughly the transcript with pieces removed, in the
/// same order. Anything that does not look like that is rejected and StupidTalk falls
/// back to the rule-based clean-up, so your words are never replaced by an invention.
public enum CleanupValidator {
    static let replyMarkers = [
        "i'm sorry", "i am sorry", "sorry, i", "sorry, but", "i can't", "i cannot", "i can not",
        "i'm unable", "i am unable", "as an ai", "as a language model", "sure,", "sure!", "sure.",
        "certainly", "of course", "here is", "here's", "here are"
    ]
    /// Words that open a question. When the transcript starts with one, the answer must still be that question.
    static let questionOpeners: Set<String> = [
        "what", "who", "whom", "whose", "where", "when", "why", "how", "which",
        "is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "would",
        "should", "will", "shall", "may", "might", "have", "has"
    ]
    static let leadingFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "okay", "ok", "so", "well", "hey", "hi"]
    /// Words the recognizer mixes up because they sound the same. Swapping one for another is a fix, not new content.
    static let soundAlikes: [Set<String>] = [
        ["to", "too", "two", "2"], ["for", "four", "4"], ["its", "it's"], ["your", "you're", "youre"],
        ["there", "their", "they're"], ["then", "than"], ["of", "off"], ["a", "an"],
        ["were", "we're", "where"], ["whose", "who's"], ["ok", "okay"], ["lets", "let's"],
        ["cant", "can't"], ["dont", "don't"], ["im", "i'm"], ["thats", "that's"], ["wont", "won't"],
        ["no", "know"], ["right", "write"], ["hear", "here"], ["by", "buy", "bye"]
    ]
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"
    ]

    /// Removes the wrapping a model sometimes adds: a "Cleaned:" label, code fences,
    /// quotes around the whole answer, or extra made-up examples after the answer.
    public static func sanitize(_ output: String, raw: String = "") -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingRegex("^```[a-zA-Z]*\\s*", with: "")
        text = text.replacingRegex("\\s*```$", with: "")
        // The model carried on with the example pattern. Keep only the first answer.
        if let range = text.range(of: "\nTranscript:", options: [.caseInsensitive]) {
            text = String(text[..<range.lowerBound])
        }
        text = text.replacingRegex("(?i)^(?:here(?:'s|\u{2019}s| is)\\s+(?:the\\s+|your\\s+)?(?:cleaned|corrected|fixed|polished)[^:\\n]{0,40}:|cleaned(?:[ -]up)?(?:\\s+(?:text|transcript|version))?\\s*:|output\\s*:|result\\s*:)\\s*", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("`", "`")]
        for (open, close) in quotePairs {
            guard text.count >= 2, text.first == open, text.last == close else { continue }
            if rawTrimmed.first == open { continue }
            let inner = text.dropFirst().dropLast()
            // Only unwrap when the quotes wrap the whole answer, not a quote inside it.
            if !inner.contains(open) && !inner.contains(close) {
                text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    public static func validate(raw: String, modelOutput: String) -> CleanupVerdict {
        let cleaned = sanitize(modelOutput, raw: raw)
        guard !cleaned.isEmpty else { return .rejected("empty answer") }

        let rawTokens = Words.tokens(raw)
        let outTokens = Words.tokens(cleaned)
        guard !outTokens.isEmpty else { return .rejected("answer has no words") }
        guard !rawTokens.isEmpty else { return .rejected("nothing was said") }

        if outTokens.count > Int(Double(rawTokens.count) * 1.25) + 4 {
            return .rejected("answer is longer than what was said")
        }
        if rawTokens.count >= 12 && Double(outTokens.count) < Double(rawTokens.count) * 0.35 {
            return .rejected("answer dropped most of what was said")
        }

        let lowerOut = cleaned.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let lowerRaw = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for marker in replyMarkers where lowerOut.hasPrefix(marker) && !lowerRaw.contains(marker) {
            return .rejected("model replied instead of cleaning")
        }

        // A dictated question has to stay a question. "What is the capital of France" must not come back as an answer.
        if let opener = rawTokens.first(where: { !leadingFillers.contains($0) }), questionOpeners.contains(opener) {
            let stillStartsTheSame = outTokens.first(where: { !leadingFillers.contains($0) }).map { sameWord($0, opener) } ?? false
            let rawIsOnlyAQuestion = !raw.contains(".") && !raw.contains("!")
            if !stillStartsTheSame && rawIsOnlyAQuestion && !cleaned.contains("?") {
                return .rejected("model answered the question instead of cleaning it")
            }
        }

        let common = commonInOrder(outTokens, rawTokens)
        let ratio = Double(common) / Double(outTokens.count)
        let needed: Double
        switch outTokens.count {
        case ..<4: needed = 0.5
        default: needed = 0.7
        }
        if ratio < needed {
            return .rejected("answer does not follow what was said")
        }
        return .accepted(cleaned)
    }

    /// How many words of `a` also appear in `b`, in the same order (longest common subsequence),
    /// counting small spelling differences as the same word.
    static func commonInOrder(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if sameWord(a[i - 1], b[j - 1]) {
                    current[j] = previous[j - 1] + 1
                } else {
                    current[j] = Swift.max(previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func sameWord(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if let left = numberWords[lhs], left == rhs { return true }
        if let right = numberWords[rhs], right == lhs { return true }
        for group in soundAlikes where group.contains(lhs) && group.contains(rhs) { return true }
        // "I'm" against "I", "we'll" against "we".
        let leftBase = lhs.split(separator: "'").first.map(String.init) ?? lhs
        let rightBase = rhs.split(separator: "'").first.map(String.init) ?? rhs
        if leftBase == rightBase && !leftBase.isEmpty { return true }
        // A fixed spelling or a different ending: "recieve" and "receive", "meet" and "meeting".
        if lhs.count >= 4 && rhs.count >= 4 && lhs.first == rhs.first {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
            return Words.editDistance(lhs, rhs, limit: 2) <= 2
        }
        return false
    }
}
