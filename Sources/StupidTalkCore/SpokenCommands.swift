import Foundation

/// Spoken formatting, turned into the real thing at once, with no AI:
/// "new line", "new paragraph", "bullet point", "open bracket ... close bracket",
/// "comma", "full stop", "question mark", "exclamation mark", "semicolon".
///
/// A command only counts when it is not part of a normal sentence:
/// "a new line of shoes" and "come to a full stop" are left alone.
public enum SpokenCommands {
    struct Command {
        /// The spoken words, as a regular expression without groups.
        let words: String
        let output: String
        /// Punctuation the recognizer put right after the words that should stay (".", "?" after a bracket).
        let keepsSentenceEnd: Bool
        /// Line breaks and brackets keep a full stop said before them: "Dear Sam. New paragraph."
        var keepsSentenceEndBefore = false
    }

    /// Commands that only change punctuation. They can run before anything else.
    static let punctuation: [Command] = [
        Command(words: "question mark", output: "?", keepsSentenceEnd: false),
        Command(words: "exclamation (?:mark|point)", output: "!", keepsSentenceEnd: false),
        Command(words: "full stop", output: ".", keepsSentenceEnd: false),
        Command(words: "semicolon", output: ";", keepsSentenceEnd: false),
        Command(words: "comma", output: ",", keepsSentenceEnd: false)
    ]

    /// Commands that change the layout: line breaks, bullets and brackets.
    static let layout: [Command] = [
        Command(words: "new paragraph", output: "\n\n", keepsSentenceEnd: false, keepsSentenceEndBefore: true),
        Command(words: "(?:new line|line break)", output: "\n", keepsSentenceEnd: false, keepsSentenceEndBefore: true),
        Command(words: "(?:bullet point|next bullet|new bullet)", output: "\n- ", keepsSentenceEnd: false, keepsSentenceEndBefore: true),
        Command(words: "(?:open|left) (?:round )?(?:bracket|brackets|parenthesis|parentheses|paren)", output: " (", keepsSentenceEnd: false, keepsSentenceEndBefore: true),
        Command(words: "(?:close|closed|end) (?:round )?(?:bracket|brackets|parenthesis|parentheses|paren)", output: ")", keepsSentenceEnd: true)
    ]

    /// When one of these comes right before the words, they are part of a sentence: "a new line", "the comma".
    static let partOfASentenceBefore: Set<String> = [
        "a", "an", "the", "my", "our", "your", "his", "her", "its", "their", "this", "that", "these", "those",
        "another", "any", "each", "every", "some", "no", "oxford", "serial", "extra", "missing"
    ]
    /// When one of these comes right after the words, they are part of a sentence: "new line of", "full stop at".
    static let partOfASentenceAfter: Set<String> = ["of", "is", "was", "are", "were", "at", "on", "in", "for", "to", "here", "there"]

    /// All commands, in the order StupidTalk uses them.
    public static func apply(_ text: String) -> String {
        applyLayout(applyPunctuation(text))
    }

    /// "comma", "full stop", "question mark" and friends.
    public static func applyPunctuation(_ text: String) -> String {
        var result = text
        for command in punctuation {
            result = replace(command, in: result)
        }
        return result
    }

    /// "new line", "new paragraph", "bullet point", brackets.
    public static func applyLayout(_ text: String) -> String {
        var result = text
        for command in layout {
            result = replace(command, in: result)
        }
        return tidy(result)
    }

    // MARK: Matching

    static func replace(_ command: Command, in text: String) -> String {
        // Group 1: punctuation the recognizer put before the words. Group 2: punctuation after them.
        let leading = command.keepsSentenceEndBefore ? "[,;:]?" : "[,.;:]?"
        let pattern = "(?i)([ \\t]*" + leading + "[ \\t]*)\\b" + command.words + "\\b([ \\t]*[,.;:!?]?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = match.range
            let wordsStart = match.range(at: 1).location + match.range(at: 1).length
            let before = previousWord(in: ns, before: wordsStart)
            let after = nextWord(in: ns, from: whole.location + whole.length)
            let isSentence = before.map { partOfASentenceBefore.contains($0) } == true
                || after.map { partOfASentenceAfter.contains($0) } == true
            result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            if isSentence {
                result += ns.substring(with: whole)
            } else {
                if command.output.hasPrefix("\n- "), result.hasSuffix("\n") {
                    // "new line, bullet point" is one line break, not two.
                    result += "- "
                } else {
                    result += command.output
                }
                let trailing = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if command.keepsSentenceEnd, [".", "!", "?"].contains(trailing) {
                    result += trailing
                }
                // Keep a space before the next word.
                let next = whole.location + whole.length
                if next < ns.length, !command.output.hasSuffix(" "), !command.output.hasSuffix("\n") {
                    let character = ns.substring(with: NSRange(location: next, length: 1))
                    if let scalar = character.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) {
                        result += " "
                    }
                }
            }
            cursor = whole.location + whole.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    static func previousWord(in text: NSString, before index: Int) -> String? {
        var end = index
        while end > 0, !isWordCharacter(text.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        guard start < end else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    static func nextWord(in text: NSString, from index: Int) -> String? {
        var start = index
        while start < text.length, !isWordCharacter(text.character(at: start)) {
            // A sentence end in between means the next word belongs to a new sentence.
            let character = text.character(at: start)
            if character == 46 || character == 33 || character == 63 || character == 10 { return nil }
            start += 1
        }
        var end = start
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        guard start < end else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 39
    }

    // MARK: Tidy

    /// Cleans up the spaces and stray punctuation around line breaks and brackets.
    static func tidy(_ text: String) -> String {
        var result = text
        // Spaces around line breaks go, but a bullet keeps its "- ".
        result = result.replacingRegex("[ \\t]*\\n[ \\t]*", with: "\n")
        result = result.replacingRegex("\\n- [ \\t]+", with: "\n- ")
        // Punctuation the recognizer put at the start of a new line.
        result = result.replacingRegex("\\n([-]? ?)[,.;:]+[ \\t]*", with: "\n$1")
        result = result.replacingRegex("\\n{3,}", with: "\n\n")
        // An empty bullet, from "bullet point" said twice.
        result = result.replacingRegex("(?m)^- *$\\n?", with: "")
        // Brackets hug their words.
        result = result.replacingRegex("\\( +", with: "(")
        result = result.replacingRegex(" +\\)", with: ")")
        result = result.replacingRegex("([^\\s(\\n])\\(", with: "$1 (")
        result = result.replacingRegex("\\(\\s*\\)", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
