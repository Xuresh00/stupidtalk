import Foundation
import Testing
@testable import StupidTalkCore

@Suite("Typing without the clipboard")
struct TypingChunksTests {
    @Test func shortTextIsOneKeyPress() {
        #expect(TypingChunks.split("Hello world") == [.text("Hello world")])
        #expect(TypingChunks.split("") == [])
    }

    @Test func longTextIsSplitIntoSmallPieces() {
        let chunks = TypingChunks.split("abcdefghijklmnopqrstuvwxyz")
        #expect(chunks == [.text("abcdefghijklmnop"), .text("qrstuvwxyz")])
        let rebuilt = chunks.map { chunk -> String in
            if case .text(let piece) = chunk { return piece }
            return "\n"
        }.joined()
        #expect(rebuilt == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test func lineBreaksBecomeKeyPresses() {
        #expect(TypingChunks.split("one\ntwo") == [.text("one"), .lineBreak, .text("two")])
        #expect(TypingChunks.split("a\n\nb") == [.text("a"), .lineBreak, .lineBreak, .text("b")])
        #expect(TypingChunks.split("a\r\nb") == [.text("a"), .lineBreak, .text("b")])
    }

    @Test func neverSplitsACharacter() {
        let emoji = String(repeating: "😀", count: 9)
        let chunks = TypingChunks.split(emoji)
        #expect(chunks == [.text(String(repeating: "😀", count: 8)), .text("😀")])
        for chunk in chunks {
            if case .text(let piece) = chunk {
                #expect(piece.utf16.count <= TypingChunks.maxUnitsPerEvent)
            }
        }
    }
}

@Suite("Cutting silence off a recording")
struct AudioTrimTests {
    private func tone(seconds: Double, level: Float) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { index in level * Float(sin(Double(index) * 2 * .pi * 220 / 16_000)) }
    }

    @Test func silenceGivesNothing() {
        #expect(AudioTrim.speechRange([Float](repeating: 0, count: 32_000)) == nil)
        #expect(AudioTrim.speechRange(tone(seconds: 1, level: 0.0005)) == nil)
        #expect(AudioTrim.speechRange([]) == nil)
    }

    @Test func keepsTheVoiceWithPadding() {
        let quiet = [Float](repeating: 0, count: 32_000) // 2 s
        let voice = tone(seconds: 1, level: 0.2)
        let samples = quiet + voice + quiet
        let range = try! #require(AudioTrim.speechRange(samples))
        // The voice is 32_000..<48_000, padding is 0.35 s = 5_600 samples on each side.
        #expect(range.lowerBound <= 32_000 - 5_000)
        #expect(range.lowerBound >= 32_000 - 6_000)
        #expect(range.upperBound >= 48_000 + 5_000)
        #expect(range.upperBound <= 48_000 + 6_500)
    }

    @Test func keepsAQuietSpeakerToo() {
        let samples = [Float](repeating: 0, count: 8_000) + tone(seconds: 1, level: 0.01) + [Float](repeating: 0, count: 8_000)
        #expect(AudioTrim.speechRange(samples) != nil)
    }

    @Test func allVoiceKeepsEverything() {
        let samples = tone(seconds: 2, level: 0.1)
        #expect(AudioTrim.speechRange(samples) == 0..<samples.count)
    }
}

@Suite("Near misses from the word list")
struct FuzzyWordsTests {
    private let vocabulary = Vocabulary.starter

    @Test func fixesNamesTheModelAlmostGotRight() {
        #expect(vocabulary.applyFuzzyCorrections(to: "I opened stupid dark again") == "I opened StupidTalk again")
        #expect(vocabulary.applyFuzzyCorrections(to: "stupid tok is my app") == "StupidTalk is my app")
        #expect(vocabulary.applyFuzzyCorrections(to: "the stupid designer website") == "the Stupidesigner website")
        #expect(vocabulary.applyFuzzyCorrections(to: "Stupid Talk.") == "StupidTalk.")
    }

    @Test func keepsPunctuationAroundTheWord() {
        #expect(vocabulary.applyFuzzyCorrections(to: "(stupid dark), right?") == "(StupidTalk), right?")
        #expect(vocabulary.applyFuzzyCorrections(to: "try stupid talk!") == "try StupidTalk!")
    }

    @Test func leavesNormalSentencesAlone() {
        let sentences = [
            "that was a stupid thing to do",
            "the stupid dog ate my homework",
            "these are stupid designers",
            "stupid duck",
            "I talk too much",
            "we should stop and talk",
            "the design is done"
        ]
        for sentence in sentences {
            #expect(vocabulary.applyFuzzyCorrections(to: sentence) == sentence)
        }
    }

    @Test func doesNotGlueWordsAcrossPunctuationOrLines() {
        #expect(vocabulary.applyFuzzyCorrections(to: "stupid. dark") == "stupid. dark")
        #expect(vocabulary.applyFuzzyCorrections(to: "stupid\ndark") == "stupid\ndark")
    }

    @Test func ignoresShortAndOddWords() {
        let list = Vocabulary(entries: [VocabularyEntry(word: "Oops"), VocabularyEntry(word: "C++ (fast)")])
        #expect(list.applyFuzzyCorrections(to: "oups I did it again") == "oups I did it again")
        #expect(list.applyFuzzyCorrections(to: "c fast") == "c fast")
    }

    @Test func matchesSimilarSoundingNames() {
        let list = Vocabulary(entries: [VocabularyEntry(word: "Priyanka")])
        #expect(list.applyFuzzyCorrections(to: "send it to priyankha") == "send it to Priyanka")
        #expect(list.applyFuzzyCorrections(to: "send it to Prince") == "send it to Prince")
    }

    @Test func soundexMatchesTheTextbook() {
        #expect(Soundex.code("Robert") == "R163")
        #expect(Soundex.code("Rupert") == "R163")
        #expect(Soundex.code("Ashcraft") == "A261")
        #expect(Soundex.code("Tymczak") == "T522")
        #expect(Soundex.code("Pfister") == "P236")
    }

    @Test func pipelineUsesThem() {
        #expect(CleanupPipeline.prepare(raw: "open  stupid dark   now", vocabulary: vocabulary) == "open StupidTalk now")
    }
}

@Suite("What the README promises")
struct ReadmeExampleTests {
    @Test func theExampleComesOutAsShown() {
        // How the speech model writes it down, punctuation and all.
        let heard = "Um, so send the the thumbnails to Sam on Monday, no wait, Tuesday, and uh tell him the font is fixed."
        let vocabulary = Vocabulary.starter
        let prepared = CleanupPipeline.prepare(raw: heard, vocabulary: vocabulary)
        let plan = CleanupPipeline.plan(prepared: prepared, vocabulary: vocabulary)
        #expect(plan.ruleText == "So send the thumbnails to Sam on Tuesday, and tell him the font is fixed.")
    }
}
