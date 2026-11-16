import Foundation
import Testing
@testable import StupidTalkCore

@Suite("Rule-based clean-up")
struct RuleCleanerTests {
    @Test func removesFillerSounds() {
        #expect(RuleCleaner.clean("um so I think we should go") == "So I think we should go")
        #expect(RuleCleaner.clean("I think, um, we should go") == "I think we should go")
        #expect(RuleCleaner.clean("Uh, hello there") == "Hello there")
        #expect(RuleCleaner.clean("we could uhh meet umm tomorrow") == "We could meet tomorrow")
    }

    @Test func keepsWordsThatOnlyLookLikeFillers() {
        #expect(RuleCleaner.clean("the umbrella is in the summer house") == "The umbrella is in the summer house")
        #expect(RuleCleaner.clean("uh-huh that works") == "Uh-huh that works")
        #expect(RuleCleaner.clean("she hummed a tune") == "She hummed a tune")
    }

    @Test func collapsesAccidentalRepeats() {
        #expect(RuleCleaner.clean("send me the the file") == "Send me the file")
        #expect(RuleCleaner.clean("I I I think so") == "I think so")
        #expect(RuleCleaner.clean("it is is ready") == "It is ready")
    }

    @Test func keepsRepeatsThatCanBeMeant() {
        #expect(RuleCleaner.clean("that was very very good") == "That was very very good")
        #expect(RuleCleaner.clean("no no that is wrong") == "No no that is wrong")
        #expect(RuleCleaner.clean("he had had enough") == "He had had enough")
    }

    @Test func fixesLoneI() {
        #expect(RuleCleaner.clean("so i think i'm late") == "So I think I'm late")
        #expect(RuleCleaner.clean("this is it") == "This is it")
    }

    @Test func capitalizesSentencesButNotAbbreviations() {
        #expect(RuleCleaner.clean("it works. um, we can ship it") == "It works. We can ship it")
        #expect(RuleCleaner.clean("meet me at 3 p.m. tomorrow") == "Meet me at 3 p.m. tomorrow")
        #expect(RuleCleaner.clean("version 2.5 is out") == "Version 2.5 is out")
        #expect(RuleCleaner.clean("ask Mr. smith e.g. today") == "Ask Mr. smith e.g. today")
    }

    @Test func tidiesPunctuationAfterRemovals() {
        #expect(RuleCleaner.clean("I agree, um.") == "I agree.")
        #expect(RuleCleaner.clean("well , that is  odd") == "Well, that is odd")
        #expect(RuleCleaner.clean("   ") == "")
    }
}

@Suite("Personal word list")
struct VocabularyTests {
    let vocabulary = Vocabulary(entries: [
        VocabularyEntry(word: "Stupidesigner", soundsLike: ["stupid designer"]),
        VocabularyEntry(word: "ThumbCheck", soundsLike: ["thumb check", "thumbs check"]),
        VocabularyEntry(word: "Mr. Oops", soundsLike: ["mister oops", "mr oops"])
    ])

    @Test func replacesSoundAlikes() {
        #expect(vocabulary.applyReplacements(to: "I work at stupid designer") == "I work at Stupidesigner")
        #expect(vocabulary.applyReplacements(to: "open Thumb Check now") == "open ThumbCheck now")
        #expect(vocabulary.applyReplacements(to: "say hi to mister oops") == "say hi to Mr. Oops")
    }

    @Test func fixesCapitalsOfTheWordItself() {
        #expect(vocabulary.applyReplacements(to: "thumbcheck is live") == "ThumbCheck is live")
        #expect(vocabulary.applyReplacements(to: "STUPIDESIGNER rocks") == "Stupidesigner rocks")
    }

    @Test func onlyTouchesWholeWords() {
        #expect(vocabulary.applyReplacements(to: "a stupid designers club") == "a stupid designers club")
        #expect(vocabulary.applyReplacements(to: "stupid designer's site") == "Stupidesigner's site")
    }

    @Test func handlesSpecialCharactersSafely() {
        let odd = Vocabulary(entries: [VocabularyEntry(word: "C++ (fast)", soundsLike: ["see plus plus"]), VocabularyEntry(word: "$100", soundsLike: ["hundred bucks"])])
        #expect(odd.applyReplacements(to: "I like see plus plus") == "I like C++ (fast)")
        #expect(odd.applyReplacements(to: "that costs hundred bucks") == "that costs $100")
    }

    @Test func listsWordsOnce() {
        let list = Vocabulary(entries: [VocabularyEntry(word: "Oops"), VocabularyEntry(word: " oops "), VocabularyEntry(word: "")])
        #expect(list.words == ["Oops"])
    }

    @Test func survivesSavingAndLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stupidtalk-vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        VocabularyFile.save(vocabulary, to: url)
        #expect(VocabularyFile.load(from: url) == vocabulary)
    }
}

@Suite("Checks on the AI answer")
struct CleanupValidatorTests {
    @Test func acceptsARealCleanUp() {
        let raw = "um so I was thinking we could uh meet on Monday no wait Tuesday at like 3 pm"
        let out = "So I was thinking we could meet on Tuesday at 3 pm."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: out) == .accepted(out))
    }

    @Test func acceptsASelfCorrectionThatDropsALot() {
        let raw = "send it to John no sorry send it to Priya"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: "Send it to Priya.") == .accepted("Send it to Priya."))
    }

    @Test func acceptsSpellingAndNumberFixes() {
        let raw = "i will recieve three boxes tomorow definately"
        let out = "I will receive 3 boxes tomorrow, definitely."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: out) == .accepted(out))
    }

    @Test func rejectsAnAnswerToAQuestion() {
        let verdict = CleanupValidator.validate(raw: "what is the capital of France", modelOutput: "The capital of France is Paris.")
        #expect(verdict == .rejected("model answered the question instead of cleaning it"))
        let opinion = CleanupValidator.validate(raw: "um do you think this is a good idea", modelOutput: "Yes, I think it is a good idea.")
        #expect(opinion == .rejected("model answered the question instead of cleaning it"))
    }

    @Test func rejectsARewriteThatChangesTheMessage() {
        let raw = "tell the client the thumbnail is late"
        let out = "The client should know that the thumbnail will arrive on Thursday."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: out) == .rejected("answer does not follow what was said"))
    }

    @Test func acceptsSoundAlikeFixes() {
        let out = "Let's meet at two."
        #expect(CleanupValidator.validate(raw: "um lets meat at too", modelOutput: out) == .accepted(out))
        let second = "They're going to the store, and it's too late."
        #expect(CleanupValidator.validate(raw: "their going too the store and its to late", modelOutput: second) == .accepted(second))
    }

    @Test func keepsAQuestionAQuestion() {
        let out = "What is the capital of France?"
        #expect(CleanupValidator.validate(raw: "what is the capital of France", modelOutput: out) == .accepted(out))
    }

    @Test func rejectsFollowingAnInstruction() {
        let raw = "can you write me a poem about the ocean"
        let poem = "The ocean rolls beneath the moon, its waves a silver, endless tune. The gulls call out across the foam, and every tide comes rolling home."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: poem) == .rejected("answer is longer than what was said"))
    }

    @Test func rejectsApologiesAndChat() {
        let raw = "tell the client the thumbnail is late"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: "I'm sorry, but I can't help with that.") == .rejected("model replied instead of cleaning"))
        #expect(CleanupValidator.validate(raw: raw, modelOutput: "") == .rejected("empty answer"))
    }

    @Test func allowsSorryWhenTheSpeakerSaidIt() {
        let raw = "i'm sorry i can't make it today"
        let out = "I'm sorry, I can't make it today."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: out) == .accepted(out))
    }

    @Test func rejectsASummary() {
        let raw = "so the plan for tomorrow is that we first finish the three thumbnails for the history channel then we send them to Sam for review and after lunch we start on the script for the new video about fonts"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: "Plan: thumbnails, review, script.") == .rejected("answer dropped most of what was said"))
    }

    @Test func stripsLabelsQuotesAndExtraExamples() {
        #expect(CleanupValidator.sanitize("Cleaned: Hello there.") == "Hello there.")
        #expect(CleanupValidator.sanitize("Here is the cleaned text:\nHello there.") == "Hello there.")
        #expect(CleanupValidator.sanitize("\"Hello there.\"") == "Hello there.")
        #expect(CleanupValidator.sanitize("```\nHello there.\n```") == "Hello there.")
        #expect(CleanupValidator.sanitize("Hello there.\n\nTranscript: something else\nCleaned: Something else.") == "Hello there.")
        #expect(CleanupValidator.sanitize("She said \"hi\" and left.") == "She said \"hi\" and left.")
    }
}

@Suite("Long dictations")
struct TextChunkerTests {
    @Test func shortTextStaysWhole() {
        #expect(TextChunker.chunks("Hello there. How are you?", maxWords: 50) == ["Hello there. How are you?"])
        #expect(TextChunker.chunks("   ", maxWords: 50) == [])
    }

    @Test func splitsAtSentences() {
        let text = "One two three. Four five six. Seven eight nine. Ten eleven twelve."
        #expect(TextChunker.chunks(text, maxWords: 6) == ["One two three. Four five six.", "Seven eight nine. Ten eleven twelve."])
    }

    @Test func cutsAnEndlessSentence() {
        let words = (1...25).map { "word\($0)" }.joined(separator: " ")
        let chunks = TextChunker.chunks(words, maxWords: 10)
        #expect(chunks.count == 3)
        #expect(chunks.map { Words.count($0) } == [10, 10, 5])
        #expect(chunks.joined(separator: " ") == words)
    }

    @Test func losesNoWords() {
        let text = String(repeating: "This is a sentence with seven words. ", count: 40)
        let chunks = TextChunker.chunks(text, maxWords: 50)
        #expect(chunks.allSatisfy { Words.count($0) <= 50 })
        #expect(chunks.map { Words.count($0) }.reduce(0, +) == Words.count(text))
    }
}

@Suite("Hold to talk")
struct HoldToTalkTests {
    func flags(_ bits: UInt, _ choice: HotkeyChoice = .rightOption) -> ModifierSnapshot {
        ModifierSnapshot(rawFlags: bits, choice: choice)
    }
    let rightOption = ModifierBits.option | ModifierBits.rightOption
    let leftOption = ModifierBits.option | ModifierBits.leftOption

    @Test func holdAndReleaseDictates() {
        var machine = HoldToTalk()
        #expect(machine.handle(.modifiers(flags(rightOption), time: 10)) == .start)
        #expect(machine.isRecording)
        #expect(machine.handle(.modifiers(flags(0), time: 12)) == .finish)
        #expect(!machine.isRecording)
    }

    @Test func aQuickTapIsIgnored() {
        var machine = HoldToTalk()
        #expect(machine.handle(.modifiers(flags(rightOption), time: 10)) == .start)
        #expect(machine.handle(.modifiers(flags(0), time: 10.1)) == .cancel)
    }

    @Test func typingAShortcutCancels() {
        var machine = HoldToTalk()
        #expect(machine.handle(.modifiers(flags(rightOption), time: 1)) == .start)
        #expect(machine.handle(.otherKeyDown) == .cancel)
        #expect(machine.handle(.modifiers(flags(0), time: 3)) == .none)
    }

    @Test func escapeCancels() {
        var machine = HoldToTalk()
        #expect(machine.handle(.escape) == .none)
        #expect(machine.handle(.modifiers(flags(rightOption), time: 1)) == .start)
        #expect(machine.handle(.escape) == .cancel)
    }

    @Test func otherModifiersDoNotStartADictation() {
        var machine = HoldToTalk()
        #expect(machine.handle(.modifiers(flags(ModifierBits.command | ModifierBits.leftCommand), time: 1)) == .none)
        #expect(machine.handle(.modifiers(flags(ModifierBits.command | ModifierBits.leftCommand | rightOption), time: 1.1)) == .none)
        #expect(machine.handle(.modifiers(flags(ModifierBits.command | ModifierBits.leftCommand), time: 2)) == .none)
        #expect(machine.handle(.modifiers(flags(0), time: 2.1)) == .none)
        // The left Option key is a different key.
        #expect(machine.handle(.modifiers(flags(leftOption), time: 3)) == .none)
    }

    @Test func addingAModifierWhileHoldingCancels() {
        var machine = HoldToTalk()
        #expect(machine.handle(.modifiers(flags(rightOption), time: 1)) == .start)
        #expect(machine.handle(.modifiers(flags(rightOption | ModifierBits.shift), time: 1.5)) == .cancel)
        #expect(machine.handle(.modifiers(flags(0), time: 2)) == .none)
    }

    @Test func worksForEveryHotkeyChoice() {
        let cases: [(HotkeyChoice, UInt)] = [
            (.rightOption, ModifierBits.option | ModifierBits.rightOption),
            (.rightCommand, ModifierBits.command | ModifierBits.rightCommand),
            (.fn, ModifierBits.function)
        ]
        for (choice, bits) in cases {
            var machine = HoldToTalk()
            #expect(machine.handle(.modifiers(ModifierSnapshot(rawFlags: bits, choice: choice), time: 0)) == .start)
            #expect(machine.handle(.modifiers(ModifierSnapshot(rawFlags: 0, choice: choice), time: 1)) == .finish)
        }
    }
}

@Suite("History and pipeline")
struct HistoryAndPipelineTests {
    @Test func historyKeepsNewestFirstAndRespectsTheLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stupidtalk-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url, limit: 3)
        for index in 1...5 {
            store.add(HistoryEntry(raw: "raw \(index)", cleaned: "Clean \(index)", usedAI: index % 2 == 0))
        }
        #expect(store.entries.map(\.cleaned) == ["Clean 5", "Clean 4", "Clean 3"])

        let reopened = HistoryStore(fileURL: url, limit: 3)
        #expect(reopened.entries.map(\.raw) == ["raw 5", "raw 4", "raw 3"])
        reopened.remove(id: reopened.entries[0].id)
        #expect(reopened.entries.count == 2)
        reopened.clear()
        #expect(HistoryStore(fileURL: url, limit: 3).entries.isEmpty)
    }

    @Test func pipelineUsesTheModelWhenItBehaves() {
        let vocabulary = Vocabulary(entries: [VocabularyEntry(word: "Stupidesigner", soundsLike: ["stupid designer"])])
        let prepared = CleanupPipeline.prepare(raw: "um  welcome to stupid designer  we we make thumbnails", vocabulary: vocabulary)
        #expect(prepared == "um welcome to Stupidesigner we we make thumbnails")
        let piece = CleanupPipeline.resolve(chunk: prepared, modelOutput: "Welcome to Stupidesigner. We make thumbnails.", vocabulary: vocabulary)
        #expect(piece == CleanupPipeline.Piece(text: "Welcome to Stupidesigner. We make thumbnails.", usedAI: true))
    }

    @Test func pipelineFallsBackWhenTheModelMisbehaves() {
        let vocabulary = Vocabulary()
        let chunk = "um what is the the capital of France"
        let answered = CleanupPipeline.resolve(chunk: chunk, modelOutput: "The capital of France is Paris.", vocabulary: vocabulary)
        #expect(answered.text == "What is the capital of France")
        #expect(answered.usedAI == false)
        #expect(answered.note == "model answered the question instead of cleaning it")

        let silent = CleanupPipeline.resolve(chunk: chunk, modelOutput: nil, vocabulary: vocabulary)
        #expect(silent.text == "What is the capital of France")
        #expect(silent.usedAI == false)
    }

    @Test func pipelineSkipsTheModelForTinyTexts() {
        #expect(CleanupPipeline.wantsAI("yes please") == false)
        #expect(CleanupPipeline.wantsAI("please send me the invoice today") == true)
    }

    @Test func joinsPieces() {
        let joined = CleanupPipeline.join([
            CleanupPipeline.Piece(text: "First part.", usedAI: true),
            CleanupPipeline.Piece(text: "Second part.", usedAI: false, note: "model did not answer")
        ])
        #expect(joined.text == "First part. Second part.")
        #expect(joined.usedAI == false)
        #expect(joined.note == "model did not answer")
    }

    @Test func promptStaysSmall() {
        let instructions = CleanupPrompt.instructions(vocabulary: (1...200).map { "Word\($0)" })
        #expect(Words.count(instructions) < 700)
        #expect(instructions.contains("Word60"))
        #expect(!instructions.contains("Word61,"))
        #expect(CleanupPrompt.prompt(for: "  hello  ") == "Transcript: hello\nCleaned:")
    }

    @Test func countsWordsAndTypos() {
        #expect(Words.count("Hello, it's me — the 2nd time!") == 6)
        #expect(Words.tokens("Don\u{2019}t stop") == ["don't", "stop"])
        #expect(Words.editDistance("recieve", "receive", limit: 2) == 2)
        #expect(Words.editDistance("cat", "elephant", limit: 2) == 3)
    }
}
