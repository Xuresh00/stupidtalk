import Foundation

/// Small text helpers shared by the clean-up code.
public enum Words {
    /// Lowercased word tokens. Letters and digits form words; an apostrophe inside a word is kept.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if (scalar == "'" || scalar == "\u{2019}") && !current.isEmpty {
                current.unicodeScalars.append("'")
            } else {
                flush(&current, into: &tokens)
            }
        }
        flush(&current, into: &tokens)
        return tokens
    }

    private static func flush(_ current: inout String, into tokens: inout [String]) {
        var word = current
        while word.hasSuffix("'") { word.removeLast() }
        if !word.isEmpty { tokens.append(word.lowercased()) }
        current = ""
    }

    /// Number of words in a piece of text.
    public static func count(_ text: String) -> Int {
        tokens(text).count
    }

    /// Edit distance between two words, stopping early once it passes `limit`.
    public static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = Swift.min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

extension String {
    /// Regex replace that works the same on macOS and Linux.
    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: template)
    }

    func firstMatch(_ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
