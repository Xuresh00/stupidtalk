import Foundation

/// The parts of the clean-up that do not need a model, in the order the app runs them.
///
/// 1. `prepare` applies the personal word list to the raw transcript.
/// 2. `plan` does everything the rules can do, at once. Most dictations are finished here.
/// 3. Only when you corrected yourself in a way the rules are not sure about, the app asks the
///    on-device model to look at that part. `finish` and `resolve` check its answer and fall
///    back to the rule-based text when it fails or takes too long.
public enum CleanupPipeline {
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var usedAI: Bool
        /// Why the model's answer was not used, when it was not.
        public var note: String?

        public init(text: String, usedAI: Bool, note: String? = nil) {
            self.text = text
            self.usedAI = usedAI
            self.note = note
        }
    }

    public static func prepare(raw: String, vocabulary: Vocabulary) -> String {
        let collapsed = raw.replacingRegex("[ \\t]+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return vocabulary.applyReplacements(to: collapsed)
    }

    /// True when the text is long enough for the model to be worth the wait.
    public static func wantsAI(_ prepared: String) -> Bool {
        Words.count(prepared) >= CleanupPrompt.minimumWordsForAI
    }

    /// Spoken commands, fillers, repeats, punctuation and the word list. Instant.
    public static func ruleCleaned(_ prepared: String, vocabulary: Vocabulary) -> String {
        vocabulary.applyReplacements(to: RuleCleaner.clean(SpokenCommands.apply(prepared)))
    }

    /// Decides what to type for one chunk, given what the model returned (or nil when it failed).
    public static func resolve(chunk: String, modelOutput: String?, vocabulary: Vocabulary) -> Piece {
        guard let modelOutput else {
            return Piece(text: ruleCleaned(chunk, vocabulary: vocabulary), usedAI: false, note: "model did not answer")
        }
        switch CleanupValidator.validate(raw: chunk, modelOutput: modelOutput) {
        case .accepted(let cleaned):
            // The model may leave a spoken command as words. Apply it anyway.
            let text = vocabulary.applyReplacements(to: SpokenCommands.applyLayout(cleaned))
            return Piece(text: text, usedAI: true, note: nil)
        case .rejected(let reason):
            return Piece(text: ruleCleaned(chunk, vocabulary: vocabulary), usedAI: false, note: reason)
        }
    }

    /// What the rules can do on their own, and which part (if any) is worth the model's time.
    public struct Plan: Equatable, Sendable {
        /// What to type when the model is not used, or does not answer in time.
        public var ruleText: String
        /// Self-corrections fixed by rule.
        public var repairs: Int
        /// The stretch with corrections the rules were not sure about. nil when there is none.
        public var window: SelfCorrection.Window?

        public init(ruleText: String, repairs: Int, window: SelfCorrection.Window?) {
            self.ruleText = ruleText
            self.repairs = repairs
            self.window = window
        }
    }

    /// The fast path: fixes what can be fixed with no model at all.
    public static func plan(prepared: String, vocabulary: Vocabulary) -> Plan {
        // Spoken punctuation first, so "comma" can mark where a self-correction starts.
        let outcome = SelfCorrection.repair(SpokenCommands.applyPunctuation(prepared))
        return Plan(
            ruleText: ruleCleaned(outcome.text, vocabulary: vocabulary),
            repairs: outcome.applied,
            window: outcome.window
        )
    }

    /// Decides what to type once the model has looked at the plan's window (nil when it failed
    /// or was too slow).
    public static func finish(plan: Plan, modelOutput: String?, vocabulary: Vocabulary) -> Piece {
        guard let window = plan.window else {
            return Piece(text: plan.ruleText, usedAI: false, note: nil)
        }
        let middle = resolve(chunk: window.middle, modelOutput: modelOutput, vocabulary: vocabulary)
        guard middle.usedAI else {
            return Piece(text: plan.ruleText, usedAI: false, note: middle.note)
        }
        let parts = [
            ruleCleaned(window.before, vocabulary: vocabulary),
            middle.text,
            ruleCleaned(window.after, vocabulary: vocabulary)
        ]
        return Piece(text: parts.filter { !$0.isEmpty }.joined(separator: " "), usedAI: true, note: nil)
    }

    /// True when the text is worth sending to the model at all.
    /// Used by "on every dictation": a few words with nothing to fix are typed at once.
    public static func wantsPolish(_ ruleText: String) -> Bool {
        Words.count(ruleText) >= CleanupPrompt.minimumWordsForAI
    }

    /// Puts cleaned chunks back together.
    public static func join(_ pieces: [Piece]) -> Piece {
        let text = pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        let usedAI = !pieces.isEmpty && pieces.allSatisfy(\.usedAI)
        let notes = pieces.compactMap(\.note)
        return Piece(text: text, usedAI: usedAI, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}
