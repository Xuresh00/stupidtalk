import Foundation
import FoundationModels
import StupidTalkCore

enum AIStatus: Equatable {
    case ready
    case off(String)

    var isReady: Bool { self == .ready }
}

/// The AI clean-up, done by the language model that ships with macOS (Apple Intelligence).
/// It runs on the Mac. Nothing is sent anywhere.
///
/// Every answer goes through `CleanupPipeline.resolve`, which rejects anything that does
/// not look like a clean-up of what was said and falls back to the rule-based clean-up.
final class AICleaner {
    private let lock = NSLock()
    private var warmSession: LanguageModelSession?
    private var warmWords: [String] = []

    func status() -> AIStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .off("This Mac can't run Apple Intelligence, so the AI clean-up stays off.")
            case .appleIntelligenceNotEnabled:
                return .off("Apple Intelligence is turned off. Turn it on in System Settings to get the AI clean-up.")
            case .modelNotReady:
                return .off("macOS is still getting the model ready. Try again in a little while.")
            @unknown default:
                return .off("The on-device model isn't available right now.")
            }
        }
    }

    private func makeSession(words: [String]) -> LanguageModelSession {
        // Clean-up is a text transformation, so the guardrails meant for that job apply.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let instructions = Instructions(CleanupPrompt.instructions(vocabulary: words))
        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// Loads the model while you are still talking, so the clean-up starts without a pause.
    func warmUp(words: [String]) {
        guard status().isReady else { return }
        let session = makeSession(words: words)
        session.prewarm()
        lock.lock()
        warmSession = session
        warmWords = words
        lock.unlock()
    }

    private func takeWarmSession(words: [String]) -> LanguageModelSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = warmSession, warmWords == words else { return nil }
        warmSession = nil
        return session
    }

    /// Cleans the prepared transcript chunk by chunk.
    /// `progress` gets (chunk number, chunk count) before each chunk starts.
    func clean(prepared: String, vocabulary: Vocabulary, progress: @escaping @Sendable (Int, Int) -> Void) async -> CleanupPipeline.Piece {
        let chunks = TextChunker.chunks(prepared, maxWords: CleanupPrompt.maxWordsPerChunk)
        let words = vocabulary.words
        var pieces: [CleanupPipeline.Piece] = []
        for (index, chunk) in chunks.enumerated() {
            progress(index + 1, chunks.count)
            guard CleanupPipeline.wantsAI(chunk) else {
                // A couple of leftover words. Nothing for the model to do.
                pieces.append(CleanupPipeline.Piece(text: CleanupPipeline.ruleCleaned(chunk, vocabulary: vocabulary), usedAI: true))
                continue
            }
            let answer = await respond(to: chunk, words: words)
            pieces.append(CleanupPipeline.resolve(chunk: chunk, modelOutput: answer, vocabulary: vocabulary))
        }
        return CleanupPipeline.join(pieces)
    }

    private func respond(to chunk: String, words: [String]) async -> String? {
        let session = takeWarmSession(words: words) ?? makeSession(words: words)
        var options = GenerationOptions()
        // Always pick the most likely word. A clean-up should not be creative.
        options.sampling = .greedy
        options.maximumResponseTokens = CleanupPrompt.responseTokenLimit(forWordCount: Words.count(chunk))
        let prompt = Prompt(CleanupPrompt.prompt(for: chunk))
        let settings = options
        do {
            let answer: String = try await Race.withTimeout(seconds: 25) {
                let response: LanguageModelSession.Response<String> = try await session.respond(to: prompt, options: settings)
                return response.content
            }
            return answer
        } catch {
            Log.info("AI clean-up did not answer: \(type(of: error))")
            return nil
        }
    }
}
