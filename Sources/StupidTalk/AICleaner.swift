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
/// Speed rules:
/// - Nothing here is ever called on the main thread, except `status`, which only reads a saved value.
/// - A session is loaded ahead of time (`warmUp`), so an answer does not start with a model load.
/// - Every request has a time limit. When the model is too slow, the app types the
///   rule-based text and moves on.
///
/// Every answer goes through `CleanupPipeline`, which rejects anything that does not look
/// like a clean-up of what was said.
final class AICleaner {
    private let lock = NSLock()
    private var saved: AIStatus = .off("Checking the on-device model.")
    private var ready: LanguageModelSession?
    private var readyWords: [String] = []

    /// The last known answer. It never asks macOS, so it is safe on the main thread.
    var status: AIStatus {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    /// Asks macOS whether the on-device model can be used. Not for the main thread.
    @discardableResult
    func refreshStatus() -> AIStatus {
        let fresh = AICleaner.readStatus()
        lock.lock()
        saved = fresh
        lock.unlock()
        return fresh
    }

    private static func readStatus() -> AIStatus {
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

    /// Loads the model and lets it read the instructions ahead of time. Not for the main thread.
    /// Safe to call often: when everything is loaded already it returns at once.
    func warmUp(words: [String]) {
        guard refreshStatus().isReady else { return }
        lock.lock()
        var session = readyWords == words ? ready : nil
        lock.unlock()
        if session == nil {
            let fresh = makeSession(words: words)
            lock.lock()
            ready = fresh
            readyWords = words
            lock.unlock()
            session = fresh
        }
        session?.prewarm(promptPrefix: Prompt(CleanupPrompt.promptPrefix))
    }

    private func takeSession(words: [String]) -> LanguageModelSession {
        lock.lock()
        let session = readyWords == words ? ready : nil
        ready = nil
        lock.unlock()
        return session ?? makeSession(words: words)
    }

    /// One answer from the model, or nil when it fails or needs longer than `budget` seconds.
    func answer(for text: String, words: [String], budget: Double) async -> String? {
        let session = takeSession(words: words)
        var options = GenerationOptions()
        // Always pick the most likely word. A clean-up should not be creative.
        options.sampling = .greedy
        options.maximumResponseTokens = CleanupPrompt.responseTokenLimit(forWordCount: Words.count(text))
        let settings = options
        let prompt = Prompt(CleanupPrompt.prompt(for: text))
        do {
            let reply: String = try await Race.withTimeout(seconds: budget) {
                let response: LanguageModelSession.Response<String> = try await session.respond(to: prompt, options: settings)
                return response.content
            }
            return reply
        } catch {
            Log.info("AI clean-up gave no answer: \(type(of: error))")
            return nil
        }
    }

    /// "On every dictation" mode: the model rewrites the whole text, piece by piece.
    /// When the time runs out, the pieces that are left get the rule-based clean-up.
    func cleanAll(prepared: String, vocabulary: Vocabulary, budget: Double) async -> CleanupPipeline.Piece {
        let deadline = Date().addingTimeInterval(budget)
        let words = vocabulary.words
        var pieces: [CleanupPipeline.Piece] = []
        for chunk in TextChunker.chunks(prepared, maxWords: CleanupPrompt.maxWordsPerChunk) {
            let rules = CleanupPipeline.plan(prepared: chunk, vocabulary: vocabulary).ruleText
            guard CleanupPipeline.wantsAI(chunk) else {
                // A couple of leftover words. Nothing for the model to do.
                pieces.append(CleanupPipeline.Piece(text: rules, usedAI: true))
                continue
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0.3 else {
                pieces.append(CleanupPipeline.Piece(text: rules, usedAI: false, note: "out of time"))
                continue
            }
            let reply = await answer(for: chunk, words: words, budget: left)
            var piece = CleanupPipeline.resolve(chunk: chunk, modelOutput: reply, vocabulary: vocabulary)
            if !piece.usedAI { piece.text = rules }
            pieces.append(piece)
        }
        return CleanupPipeline.join(pieces)
    }

    /// Times two small clean-ups and writes the result to the log: the first one right after
    /// loading, the second one with everything warm. It tells how fast the model is on this Mac.
    func speedTest(words: [String]) async {
        guard status.isReady else {
            Log.info("AI speed test skipped: the on-device model is not available")
            return
        }
        let sample = "um so we could meet on Monday no wait Tuesday at like 3 pm in the the office"
        for round in ["first", "second"] {
            let loading = Date()
            warmUp(words: words)
            let loaded = Date()
            let reply = await answer(for: sample, words: words, budget: 30)
            let done = Date()
            let loadTime = Int((loaded.timeIntervalSince(loading) * 1000).rounded())
            let answerTime = Int((done.timeIntervalSince(loaded) * 1000).rounded())
            let result = reply.map { "\(Words.count($0)) words back" } ?? "no answer"
            Log.info("AI speed test (\(round)): get ready \(loadTime) ms, answer \(answerTime) ms for \(Words.count(sample)) words, \(result)")
        }
    }
}
