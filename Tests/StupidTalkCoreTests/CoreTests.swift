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

@Suite("Self-corrections fixed by rule")
struct SelfCorrectionTests {
    private func fixed(_ text: String) -> String {
        let outcome = SelfCorrection.repair(text)
        #expect(outcome.unresolved == 0, "left unresolved: \(text)")
        #expect(outcome.window == nil)
        return outcome.text
    }

    @Test func swapsTheLastWordInTheMiddleOfASentence() {
        #expect(fixed("send it on Monday, no wait, Tuesday") == "send it on Tuesday")
        #expect(fixed("I'll send the report today, no wait, tomorrow.") == "I'll send the report tomorrow.")
    }

    @Test func swapsANumberOrNameThatIsNotTheLastWord() {
        #expect(fixed("we need five copies, make that six") == "we need six copies")
        #expect(fixed("We need 5 copies, no wait, 6.") == "We need 6 copies.")
        #expect(fixed("send it to John tomorrow, no wait, Sam") == "send it to Sam tomorrow")
        #expect(fixed("Send it to me, no wait, Sam.") == "Send it to Sam.")
        #expect(fixed("Book a table for Friday at 7, no wait, Saturday.") == "Book a table for Saturday at 7.")
    }

    @Test func swapsAcrossAFullStopWhenTheWordsAreTheSameKind() {
        #expect(fixed("Let's meet at 5 pm. No wait, 6 pm.") == "Let's meet at 6 pm.")
        #expect(fixed("Send it to John. No wait, Sam.") == "Send it to Sam.")
        #expect(fixed("It costs 500. No, wait, 600.") == "It costs 600.")
    }

    @Test func restartsFromAWordYouAlreadySaid() {
        #expect(fixed("call John, no wait, call Sam about the invoice") == "call Sam about the invoice")
        #expect(fixed("I will go to the store, sorry I mean, to the market") == "I will go to the market")
        #expect(fixed("I like it. No wait, I love it.") == "I love it.")
    }

    @Test func keepsTheRestOfTheSentence() {
        #expect(fixed("on Monday, no wait, Tuesday, and bring the laptop") == "on Tuesday, and bring the laptop")
        #expect(fixed("Hi Sam. See you Monday, no wait, Tuesday. Bye.") == "Hi Sam. See you Tuesday. Bye.")
    }

    @Test func scratchThatThrowsAwayTheSentenceBefore() {
        #expect(fixed("Send the invoice today. Scratch that. Send it tomorrow.") == "Send it tomorrow.")
        #expect(fixed("Hi Sam. Send it today, scratch that, send it tomorrow.") == "Hi Sam. send it tomorrow.")
    }

    @Test func fixesTwoCorrectionsInARow() {
        #expect(fixed("on Monday, no wait, Tuesday, no wait, Wednesday") == "on Wednesday")
    }

    @Test func leavesNormalSpeechAlone() {
        let untouched = [
            "There is no wait time at the clinic.",
            "Don't go. No, wait for me.",
            "Please scratch that itch.",
            "Please delete that file today.",
            "Please make that change today.",
            "That is what I meant.",
            "I mean it.",
            "Actually, I think it is fine.",
            "It's fine. Actually, let's go.",
            "I'm sorry, I can't make it today.",
            "It's expensive. I mean, we could still buy it but it is a lot of money."
        ]
        for text in untouched {
            let outcome = SelfCorrection.repair(text)
            #expect(outcome.text == text)
            #expect(outcome.applied == 0)
            #expect(outcome.unresolved == 0, "flagged: \(text)")
        }
    }

    @Test func reportsWhatItIsNotSureAbout() {
        let unsure = [
            "The meeting is at noon. No wait, let's cancel it.",
            "the red one, actually the blue one",
            "it's blue, sorry, green",
            "See you on Monday. I mean Tuesday.",
            "send it on Monday no wait Tuesday"
        ]
        for text in unsure {
            let outcome = SelfCorrection.repair(text)
            #expect(outcome.text == text, "changed: \(text)")
            #expect(outcome.unresolved >= 1, "not flagged: \(text)")
            #expect(outcome.window != nil)
        }
    }

    @Test func givesTheModelOnlyThePartItNeeds() {
        let outcome = SelfCorrection.repair("We ship on Friday. Paint it red. The red one, actually the blue one, is better. Call me later.")
        #expect(outcome.window == SelfCorrection.Window(
            before: "We ship on Friday.",
            middle: "Paint it red. The red one, actually the blue one, is better.",
            after: "Call me later."
        ))
    }
}

@Suite("The fast path")
struct FastPathTests {
    private let vocabulary = Vocabulary(entries: [VocabularyEntry(word: "Stupidesigner", soundsLike: ["stupid designer"])])

    @Test func mostDictationsNeedNoModel() {
        let plan = CleanupPipeline.plan(prepared: "um so send it to stupid designer on Monday, no wait, Tuesday", vocabulary: vocabulary)
        #expect(plan.window == nil)
        #expect(plan.repairs == 1)
        #expect(plan.ruleText.contains("Stupidesigner"))
        #expect(plan.ruleText.contains("Tuesday"))
        #expect(!plan.ruleText.contains("Monday"))
        #expect(!plan.ruleText.lowercased().contains("no wait"))
        #expect(!plan.ruleText.lowercased().contains("um "))
        let piece = CleanupPipeline.finish(plan: plan, modelOutput: nil, vocabulary: vocabulary)
        #expect(piece == CleanupPipeline.Piece(text: plan.ruleText, usedAI: false))
    }

    @Test func theModelOnlyRewritesItsWindow() {
        let plan = CleanupPipeline.plan(prepared: "We ship on Friday. Paint it red. The red one, actually the blue one, is better. Call me later.", vocabulary: vocabulary)
        #expect(plan.window != nil)
        let good = CleanupPipeline.finish(plan: plan, modelOutput: "Paint it red. The blue one is better.", vocabulary: vocabulary)
        #expect(good == CleanupPipeline.Piece(text: "We ship on Friday. Paint it red. The blue one is better. Call me later.", usedAI: true))

        let silent = CleanupPipeline.finish(plan: plan, modelOutput: nil, vocabulary: vocabulary)
        #expect(silent.usedAI == false)
        #expect(silent.text == plan.ruleText)
        #expect(silent.note == "model did not answer")

        let wandering = CleanupPipeline.finish(plan: plan, modelOutput: "Sure! Here is a poem about paint and the colour blue for you.", vocabulary: vocabulary)
        #expect(wandering.usedAI == false)
        #expect(wandering.text == plan.ruleText)
    }

    @Test func oldHistoryFilesStillLoad() throws {
        let old = """
        [{"id":"7C0F0E0A-0000-4000-8000-000000000001","date":"2026-11-16T16:20:39Z","raw":"hello","cleaned":"Hello","usedAI":false,"seconds":2.5}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([HistoryEntry].self, from: Data(old.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].wait == nil)
        #expect(HistoryEntry(raw: "a", cleaned: "A", usedAI: false, wait: 0.4).wait == 0.4)
    }
}

@Suite("Spoken commands")
struct SpokenCommandTests {
    private let none = Vocabulary(entries: [])

    private func cleaned(_ text: String) -> String {
        CleanupPipeline.plan(prepared: CleanupPipeline.prepare(raw: text, vocabulary: none), vocabulary: none).ruleText
    }

    @Test func lineBreaksAndParagraphs() {
        #expect(cleaned("banana, new line, potato") == "Banana\nPotato")
        #expect(cleaned("Dear Sam. New paragraph. The file is ready.") == "Dear Sam.\n\nThe file is ready.")
        #expect(cleaned("first line new line second line") == "First line\nSecond line")
    }

    @Test func bullets() {
        #expect(cleaned("Shopping list, new line, bullet point eggs bullet point milk, bullet point bread") == "Shopping list\n- Eggs\n- Milk\n- Bread")
        #expect(cleaned("bullet point apples bullet point oranges") == "- Apples\n- Oranges")
    }

    @Test func brackets() {
        #expect(cleaned("I'll meet you at the market, open bracket, the big one, close bracket, tomorrow.") == "I'll meet you at the market (the big one) tomorrow.")
        #expect(cleaned("Bring the charger open bracket the white one close bracket.") == "Bring the charger (the white one).")
    }

    @Test func punctuationWords() {
        #expect(cleaned("is it ready question mark") == "Is it ready?")
        #expect(cleaned("Send it today full stop thanks a lot exclamation mark") == "Send it today. Thanks a lot!")
        #expect(cleaned("we need milk comma eggs comma and bread") == "We need milk, eggs, and bread")
    }

    @Test func leavesNormalSentencesAlone() {
        let untouched = [
            "We are launching a new line of shoes.",
            "The car came to a full stop.",
            "The comma is missing.",
            "That bullet point is too long.",
            "Read the new paragraph first.",
            "The right bracket for your income is lower."
        ]
        for text in untouched {
            #expect(cleaned(text) == text, "changed: \(text)")
        }
    }

    @Test func runningTheRulesTwiceChangesNothing() {
        let samples = [
            "um so send it to Sam on Monday, no wait, Tuesday, new line, thanks",
            "Shopping list new line bullet point eggs bullet point milk",
            "the market open bracket the big one close bracket is closed"
        ]
        for sample in samples {
            let once = cleaned(sample)
            #expect(CleanupPipeline.ruleCleaned(once, vocabulary: none) == once, "not stable: \(sample)")
        }
    }
}

@Suite("Polished answers the checker accepts")
struct PolishTests {
    private let none = Vocabulary(entries: [])

    @Test func aListIsAccepted() {
        let raw = "Let's make a list. Let's add, banana, potato milk, bread."
        let answer = "Let's make a list:\n- Banana\n- Potato\n- Milk\n- Bread"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: answer) == .accepted(answer))
        let piece = CleanupPipeline.resolve(chunk: raw, modelOutput: answer, vocabulary: none)
        #expect(piece == CleanupPipeline.Piece(text: answer, usedAI: true))
    }

    @Test func numberedStepsAreAccepted() {
        let raw = "first open the app second press record third talk"
        let answer = "1. Open the app.\n2. Press record.\n3. Talk."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: answer) == .accepted(answer))
    }

    @Test func smallGrammarFixesAreAccepted() {
        let raw = "The only problem is that when I release the key, it's ask me to paste it."
        let answer = "The only problem is that when I release the key, it asks me to paste it."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: answer) == .accepted(answer))
    }

    @Test func bracketsAreAccepted() {
        let raw = "I'll meet you at the market which is the big one tomorrow"
        let answer = "I'll meet you at the market (the big one) tomorrow."
        #expect(CleanupValidator.validate(raw: raw, modelOutput: answer) == .accepted(answer))
    }

    @Test func aListCannotSneakInNewItems() {
        let raw = "add milk and bread to the list"
        let answer = "Add to the list:\n- Milk\n- Bread\n- Eggs\n- Butter\n- Cheese\n- Apples\n- Rice"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: answer) != .accepted(answer))
    }

    @Test func stillNoAnswersToQuestions() {
        let raw = "What is the capital of France?"
        #expect(CleanupValidator.validate(raw: raw, modelOutput: "The capital of France is Paris.") != .accepted("The capital of France is Paris."))
    }
}

