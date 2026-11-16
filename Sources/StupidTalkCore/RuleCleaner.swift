import Foundation

/// Clean-up that needs no AI.
///
/// It is the fallback when the AI clean-up is switched off, is not available on this Mac,
/// or returns something that fails the safety checks in `CleanupValidator`.
/// It only does things that are safe without understanding the sentence:
/// filler sounds, accidental repeats, and tidy punctuation.
public enum RuleCleaner {
    static let boundaryBefore = "(?<![\\p{L}\\p{N}'\u{2019}-])"
    static let boundaryAfter = "(?![\\p{L}\\p{N}'\u{2019}-])"
    /// um, umm, uh, uhh, uhm, erm
    static let fillerPattern = "(?:u+m+|u+h+m*|e+r+m+)"
    /// Small words that are almost never repeated on purpose.
    static let repeatableWords = "the|a|an|to|of|in|on|at|for|and|but|or|is|are|was|were|be|i|we|you|he|she|it|they|my|your|our|this|with|from|as|if|can|will|would|should|could|do|does|did|have|has|not"
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "no", "e.g", "i.e", "a.m", "p.m", "approx", "inc", "ltd", "jr", "sr"]

    public static func clean(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingRegex("[ \\t]+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // 1. Filler sounds. When commas wrap the filler ("we could, um, meet") both commas go.
        text = text.replacingRegex("(?i)\\s*[,;]\\s*" + boundaryBefore + fillerPattern + boundaryAfter + "\\s*[,;]", with: " ")
        text = text.replacingRegex("(?i)" + boundaryBefore + fillerPattern + boundaryAfter + "[,;]?", with: "")

        // 2. Words repeated by accident ("the the", "I I I").
        text = text.replacingRegex("(?i)" + boundaryBefore + "(" + repeatableWords + ")(?:[ ,]+\\1)+" + boundaryAfter, with: "$1")

        // 3. Tidy the punctuation and spaces the removals left behind.
        text = text.replacingRegex("[ \\t]+", with: " ")
        text = text.replacingRegex(" +([,.;:!?])", with: "$1")
        text = text.replacingRegex("([,;:])(?:\\s*[,;:])+", with: "$1")
        text = text.replacingRegex("[,;:]\\s*([.!?])", with: "$1")
        text = text.replacingRegex("([.!?])\\s*[,;:]+", with: "$1")
        text = text.replacingRegex("(?m)^[ \\t,;:]+", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. A lone "i" is always "I".
        text = text.replacingRegex(boundaryBefore + "i(?=['\u{2019}\\s,.!?;:]|$)", with: "I")

        // 5. Capital letter at the start of each sentence.
        return capitalizingSentences(text)
    }

    /// Capitalizes the first letter of the text and of each sentence, without touching
    /// abbreviations ("3 p.m. tomorrow"), decimals or ellipses.
    static func capitalizingSentences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var capitalizeNext = true
        var pendingSentenceEnd = false
        var currentWord = ""
        var previous: Character?

        for character in text {
            if character.isLetter || character.isNumber {
                if capitalizeNext, character.isLetter, character.isLowercase {
                    result.append(contentsOf: String(character).uppercased())
                } else {
                    result.append(character)
                }
                capitalizeNext = false
                pendingSentenceEnd = false
                currentWord.append(character)
            } else {
                result.append(character)
                if character == "." || character == "!" || character == "?" {
                    let word = currentWord.lowercased()
                    let isEllipsis = character == "." && previous == "."
                    let isAbbreviation = character == "." && (abbreviations.contains(word) || word.contains(".") || word.count == 1)
                    if character == "." {
                        // Keep building dotted words like "p.m" so the second dot is recognised too.
                        currentWord.append(character)
                    }
                    pendingSentenceEnd = !(isEllipsis || isAbbreviation)
                } else if character == "\n" {
                    capitalizeNext = true
                    pendingSentenceEnd = false
                    currentWord = ""
                } else if character.isWhitespace {
                    if pendingSentenceEnd { capitalizeNext = true }
                    pendingSentenceEnd = false
                    currentWord = ""
                } else if character == "\"" || character == "\u{201D}" || character == ")" || character == "'" || character == "\u{2019}" {
                    // Closing quotes and brackets keep a pending sentence end alive.
                } else {
                    pendingSentenceEnd = false
                }
            }
            previous = character
        }
        return result
    }
}
