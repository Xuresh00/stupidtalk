import Foundation

/// Spots the moments you correct yourself while talking ("on Monday, no wait, Tuesday")
/// and fixes the clear ones by rule, with no AI and no waiting.
///
/// It is careful on purpose. A wrong repair is worse than no repair, so anything it is
/// not sure about is left as you said it and reported as `unresolved`. The app can then
/// hand just that part to the on-device model.
public enum SelfCorrection {
    /// The part of a dictation the model should look at, with the text around it.
    public struct Window: Equatable, Sendable {
        public var before: String
        public var middle: String
        public var after: String

        public init(before: String, middle: String, after: String) {
            self.before = before
            self.middle = middle
            self.after = after
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The text with the clear corrections applied.
        public var text: String
        /// How many corrections were applied by rule.
        public var applied: Int
        /// How many corrections were spotted but left alone.
        public var unresolved: Int
        /// Sentence-aligned split around the unresolved corrections. nil when there are none.
        public var window: Window?

        public init(text: String, applied: Int, unresolved: Int, window: Window?) {
            self.text = text
            self.applied = applied
            self.unresolved = unresolved
            self.window = window
        }
    }

    // MARK: Cue phrases

    /// "Throw away what I just said."
    static let eraseCues: [[String]] = [
        ["scratch", "that"], ["strike", "that"], ["delete", "that"], ["erase", "that"]
    ]
    /// "Replace the last bit with what comes next." These are rarely anything but a correction.
    static let replaceCues: [[String]] = [
        ["sorry", "i", "mean"], ["no", "i", "mean"], ["no", "wait"], ["wait", "no"], ["no", "sorry"],
        ["i", "meant"], ["or", "rather"], ["make", "that"]
    ]
    /// Often a correction, often not ("I mean it"). Never repaired by rule, only reported.
    static let weakCues: [[String]] = [
        ["i", "mean"], ["actually", "no"], ["no", "actually"], ["let", "me", "rephrase"],
        ["sorry"], ["actually"]
    ]

    // MARK: Tokens

    struct Token {
        var text: String
        var word: String
        /// The last punctuation mark attached to the word, if any.
        var mark: Character?

        var endsSentence: Bool { mark == "." || mark == "!" || mark == "?" }
        var endsClause: Bool { mark != nil }
    }

    static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    static let marks: Set<Character> = [".", "!", "?", ",", ";", ":", "\u{2014}", "\u{2013}", "-"]

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).map { piece in
            let raw = String(piece)
            let word = raw.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var tail = Substring(raw)
            while let last = tail.last, closers.contains(last) { tail = tail.dropLast() }
            var mark: Character?
            if let last = tail.last, marks.contains(last), !word.isEmpty || raw.count == 1 {
                mark = last
            }
            return Token(text: raw, word: word, mark: mark)
        }
    }

    static func match(_ cue: [String], in tokens: [Token], at index: Int) -> Bool {
        guard index + cue.count <= tokens.count else { return false }
        for offset in 0..<cue.count where tokens[index + offset].word != cue[offset] {
            return false
        }
        // A sentence end inside the phrase means it is not one phrase ("No. Wait for me.").
        for offset in 0..<(cue.count - 1) where tokens[index + offset].endsSentence {
            return false
        }
        return true
    }

    /// First token of the sentence that `index` belongs to.
    static func sentenceStart(_ tokens: [Token], before index: Int) -> Int {
        var start = index
        while start > 0, !tokens[start - 1].endsSentence { start -= 1 }
        return start
    }

    /// Last token of the sentence that `index` belongs to.
    static func sentenceEnd(_ tokens: [Token], from index: Int) -> Int {
        var end = index
        while end < tokens.count - 1, !tokens[end].endsSentence { end += 1 }
        return end
    }

    /// Last token of the clause that starts at `index`: it stops at the first comma or sentence end.
    static func clauseEnd(_ tokens: [Token], from index: Int) -> Int {
        var end = index
        while end < tokens.count - 1, !tokens[end].endsClause { end += 1 }
        return end
    }

    enum Shape { case number, name, other }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million"
    ]

    /// Numbers ("5", "five") and names ("Monday", "Sam") can be swapped one for one.
    static func shape(_ token: Token) -> Shape {
        if token.word.contains(where: { $0.isNumber }) || numberWords.contains(token.word) { return .number }
        let letters = token.word
        if let first = token.text.first(where: { $0.isLetter }), first.isUppercase, letters.count > 1,
           letters.allSatisfy({ $0.isLetter }), token.text.dropFirst().contains(where: { $0.isLowercase }) {
            return .name
        }
        return .other
    }

    /// True when `old` holds a number or name that `new` could replace one for one.
    static func hasSameShape(as new: Token, in old: [Token]) -> Bool {
        let wanted = shape(new)
        let from = max(wanted == .name ? 1 : 0, old.count - 8)
        guard from < old.count else { return false }
        return (from..<old.count).contains(where: { shape(old[$0]) == wanted })
    }

    /// The token's text without the punctuation mark at its end.
    static func bare(_ token: Token) -> String {
        guard let mark = token.mark, token.text.last == mark else { return token.text }
        return String(token.text.dropLast())
    }

    static func token(_ text: String) -> Token {
        tokens(text).first ?? Token(text: text, word: text.lowercased(), mark: nil)
    }

    // MARK: Repair

    /// Applies the clear corrections and reports the unclear ones.
    public static func repair(_ input: String) -> Outcome {
        var tokens = self.tokens(input)
        var applied = 0

        // One repair at a time, left to right, then look again from the start.
        var repairedSomething = true
        while repairedSomething, applied < 8 {
            repairedSomething = false
            for index in tokens.indices {
                if case .repaired(let repaired)? = applyStrongCue(at: index, in: tokens) {
                    tokens = repaired
                    applied += 1
                    repairedSomething = true
                    break
                }
            }
        }

        // Whatever is still there was not clear enough to fix by rule.
        var flagged = Set<Int>()
        for index in tokens.indices {
            if applyStrongCue(at: index, in: tokens) != nil || isWeakCorrection(at: index, in: tokens) {
                flagged.insert(index)
            }
        }

        let text = tokens.map(\.text).joined(separator: " ")
        guard !flagged.isEmpty else {
            return Outcome(text: text, applied: applied, unresolved: 0, window: nil)
        }

        // The model gets the sentences that hold the unclear corrections, plus the one before,
        // because "No wait, Tuesday." only makes sense next to the sentence it corrects.
        let first = flagged.min() ?? 0
        let last = flagged.max() ?? 0
        var start = sentenceStart(tokens, before: first)
        if start > 0 { start = sentenceStart(tokens, before: start - 1) }
        let end = sentenceEnd(tokens, from: last)
        let window = Window(
            before: tokens[..<start].map(\.text).joined(separator: " "),
            middle: tokens[start...end].map(\.text).joined(separator: " "),
            after: tokens[(end + 1)...].map(\.text).joined(separator: " ")
        )
        return Outcome(text: text, applied: applied, unresolved: flagged.count, window: window)
    }

    enum Step {
        case repaired([Token])
        case unsure
    }

    /// After "no wait", these words mean it was not a correction ("no wait time", "no, wait for me").
    static let notACorrectionAfterNoWait: Set<String> = [
        "time", "times", "list", "lists", "period", "periods", "for", "to", "at", "in", "until", "till",
        "here", "there", "up", "a", "an", "required", "needed"
    ]
    /// Cues that are only trusted right after a comma or a full stop ("please make that change").
    static let needsClauseStart: Set<String> = ["make that", "or rather", "i meant"]

    /// nil when there is no strong cue at `index`.
    static func applyStrongCue(at index: Int, in tokens: [Token]) -> Step? {
        // A correction needs something before it to correct.
        guard index > 0 else { return nil }
        let startsClause = tokens[index - 1].endsClause

        for cue in eraseCues where match(cue, in: tokens, at: index) {
            let cueEnd = index + cue.count - 1
            // "scratch that itch" and "delete that file" are not corrections: the phrase has to stand alone.
            let standsAlone = cueEnd == tokens.count - 1 || tokens[cueEnd].endsClause
            guard standsAlone else { return nil }
            guard startsClause else { return .unsure }
            let start = sentenceStart(tokens, before: index - 1)
            var result = Array(tokens[..<start])
            result.append(contentsOf: tokens[(cueEnd + 1)...])
            return .repaired(result)
        }

        for cue in replaceCues where match(cue, in: tokens, at: index) {
            let cueEnd = index + cue.count - 1
            // Nothing after the cue: nothing to put in place of the old words.
            guard cueEnd < tokens.count - 1 else { return nil }
            let phrase = cue.joined(separator: " ")
            if phrase == "no wait", notACorrectionAfterNoWait.contains(tokens[cueEnd + 1].word) { return nil }
            guard startsClause else {
                return needsClauseStart.contains(phrase) ? nil : .unsure
            }

            let cueStartsSentence = tokens[index - 1].endsSentence
            let oldStart = sentenceStart(tokens, before: index - 1)
            let old = Array(tokens[oldStart..<index])
            // The correction itself runs to the next comma or full stop. The rest of the sentence stays.
            let newEnd = clauseEnd(tokens, from: cueEnd + 1)
            let new = Array(tokens[(cueEnd + 1)...newEnd])
            guard !old.isEmpty, !new.isEmpty, new.allSatisfy({ !$0.word.isEmpty }) else { return .unsure }

            var keep: Int?
            // 1. You restarted from a word you had already said: "call John, no wait, call Sam".
            let searchFrom = max(0, old.count - 10)
            if let anchor = (searchFrom..<old.count).last(where: { old[$0].word == new[0].word }) {
                keep = anchor
            } else if new.count <= 2, old.count > new.count,
                      !(new.count == 1 && shape(new[0]) != .other && hasSameShape(as: new[0], in: old)) {
                // 2. A short swap: "on Monday, no wait, Tuesday".
                let sameKind = shape(old[old.count - 1]) != .other
                    && shape(old[old.count - 1]) == shape(new[new.count - 1])
                let sameLastWord = old[old.count - 1].word == new[new.count - 1].word
                if !cueStartsSentence || sameKind || sameLastWord {
                    keep = old.count - new.count
                }
            }
            var result = Array(tokens[..<oldStart])
            if keep == nil, new.count == 1, shape(new[0]) != .other {
                // 3. One number or name for another, even when it is not the last word:
                //    "we need five copies, make that six" means six copies.
                let wanted = shape(new[0])
                let from = max(wanted == .name ? 1 : 0, old.count - 8)
                if from < old.count, let spot = (from..<old.count).last(where: { shape(old[$0]) == wanted }) {
                    var fixed = old
                    let markOfOld = old[spot].mark.map { String($0) } ?? ""
                    if spot == old.count - 1 {
                        fixed[spot] = new[0]
                    } else {
                        fixed[spot] = token(bare(new[0]) + markOfOld)
                        // The comma before "no wait" goes, and the sentence keeps the ending the correction had.
                        let ending = new[0].mark.map { String($0) } ?? ""
                        let last = fixed.count - 1
                        let body = fixed[last].mark == "," ? bare(fixed[last]) : fixed[last].text
                        fixed[last] = token(body + (fixed[last].endsSentence ? "" : ending))
                    }
                    result.append(contentsOf: fixed)
                    result.append(contentsOf: tokens[(newEnd + 1)...])
                    return .repaired(result)
                }
            }
            guard let keep else { return .unsure }

            result.append(contentsOf: old[..<keep])
            result.append(contentsOf: new)
            result.append(contentsOf: tokens[(newEnd + 1)...])
            return .repaired(result)
        }
        return nil
    }

    /// A weak cue only counts when it sits where a correction would: after a comma in the
    /// middle of a sentence, or opening a short sentence that is not the first one.
    static func isWeakCorrection(at index: Int, in tokens: [Token]) -> Bool {
        guard index > 0, tokens[index - 1].endsClause else { return false }
        // Part of a strong cue that was already looked at ("no sorry", "sorry I mean").
        if index > 0, tokens[index - 1].word == "no" || tokens[index - 1].word == "wait" { return false }
        for cue in weakCues where match(cue, in: tokens, at: index) {
            let cueEnd = index + cue.count - 1
            guard cueEnd < tokens.count - 1 else { return false }
            if !tokens[index - 1].endsSentence { return true }
            // "Actually, ..." and "Sorry, ..." open far too many normal sentences.
            guard cue.count > 1 else { return false }
            let rest = sentenceEnd(tokens, from: cueEnd + 1) - cueEnd
            return rest <= 3
        }
        return false
    }
}
