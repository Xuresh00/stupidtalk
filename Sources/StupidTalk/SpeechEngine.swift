import Foundation
import TranscribeCpp

/// Speech to text on this Mac, with transcribe.cpp: the open-source engine the Handy app
/// runs on. The model works on the GPU (Metal), and the audio never leaves the Mac.
///
/// Everything happens on one private queue, one dictation at a time: the engine allows a
/// single run per model, and a session must not be shared between threads.
final class SpeechEngine: @unchecked Sendable {
    enum EngineError: LocalizedError {
        case notLoaded

        var errorDescription: String? {
            "The speech model isn't loaded yet."
        }
    }

    struct Heard {
        let text: String
        /// How long the model took, in milliseconds.
        let milliseconds: Int
    }

    private let queue = DispatchQueue(label: "com.stupidesigner.stupidtalk.speech", qos: .userInitiated)
    private var model: Model?
    private var session: TranscribeCpp.Session?
    private var loadedPath: String?
    private var takesVocabulary = false

    /// Loads the model file onto the GPU, then runs a short warm-up so the first dictation
    /// is as quick as the rest. Returns the name of the backend in use, for the log.
    func load(_ url: URL) async throws -> String {
        try await onQueue {
            if self.loadedPath == url.path, let model = self.model, self.session != nil {
                return model.backend
            }
            self.session = nil
            self.model = nil
            self.loadedPath = nil
            try Transcribe.initBackends()
            let model = try Model(path: url.path)
            let session = try model.session()
            // Half a second of silence compiles the GPU code now, not during your first dictation.
            _ = try? session.run([Float](repeating: 0, count: 8_000), options: RunOptions(language: "en"))
            self.model = model
            self.session = session
            self.loadedPath = url.path
            self.takesVocabulary = model.supports(.vocabulary)
            return model.backend
        }
    }

    /// Frees the model's memory. Used when you switch models.
    func unload() {
        queue.async {
            self.session = nil
            self.model = nil
            self.loadedPath = nil
            self.takesVocabulary = false
        }
    }

    /// `samples`: mono, 16 kHz, between -1 and 1.
    /// `vocabulary`: your word list. Models that can use one (Whisper) get it as a hint.
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> Heard {
        try await onQueue {
            guard let session = self.session else { throw EngineError.notLoaded }
            var options = RunOptions(language: "en")
            if self.takesVocabulary, !vocabulary.isEmpty {
                options.vocabulary = Array(vocabulary.prefix(40))
            }
            let started = Date()
            let transcript = try session.run(samples, options: options)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Heard(text: text, milliseconds: milliseconds)
        }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension SpeechEngine {
    /// What went wrong, in plain words, for the pill and the setup window.
    static func plainMessage(for error: Error) -> String {
        if let engine = error as? EngineError, let text = engine.errorDescription { return text }
        guard let engineError = error as? TranscribeError else {
            return "Something went wrong. Try again."
        }
        switch engineError {
        case .modelFileNotFound, .modelLoad, .versionMismatch, .badStructSize:
            return "The speech model didn't load. Download it again in Settings."
        case .outOfMemory:
            return "Not enough free memory for the speech model. Close a big app and try again."
        case .inputTooShort:
            return "That was too short to hear."
        default:
            return "The speech model had a problem. Try again."
        }
    }
}
