import Foundation

/// The parts of the clean-up that do not need a model, in the order the app runs them.
///
/// 1. `prepare` applies the personal word list to the raw transcript.
/// 2. The app asks the on-device model to clean each chunk (when the AI clean-up is on).
/// 3. `resolve` checks each answer and falls back to the rule-based clean-up when it fails.
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

    public static func ruleCleaned(_ prepared: String, vocabulary: Vocabulary) -> String {
        vocabulary.applyReplacements(to: RuleCleaner.clean(prepared))
    }

    /// Decides what to type for one chunk, given what the model returned (or nil when it failed).
    public static func resolve(chunk: String, modelOutput: String?, vocabulary: Vocabulary) -> Piece {
        guard let modelOutput else {
            return Piece(text: ruleCleaned(chunk, vocabulary: vocabulary), usedAI: false, note: "model did not answer")
        }
        switch CleanupValidator.validate(raw: chunk, modelOutput: modelOutput) {
        case .accepted(let cleaned):
            return Piece(text: vocabulary.applyReplacements(to: cleaned), usedAI: true, note: nil)
        case .rejected(let reason):
            return Piece(text: ruleCleaned(chunk, vocabulary: vocabulary), usedAI: false, note: reason)
        }
    }

    /// Puts cleaned chunks back together.
    public static func join(_ pieces: [Piece]) -> Piece {
        let text = pieces.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        let usedAI = !pieces.isEmpty && pieces.allSatisfy(\.usedAI)
        let notes = pieces.compactMap(\.note)
        return Piece(text: text, usedAI: usedAI, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}
