import AVFoundation
import Speech

enum SpeechModelStatus: Equatable {
    case unknown
    case unavailable(String)
    case needsDownload
    case downloading(Double)
    case ready
}

enum SpeechEngineError: LocalizedError {
    case unavailable
    case languageNotSupported
    case noAudioFormat
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "On-device speech recognition isn't available on this Mac."
        case .languageNotSupported: return "That language isn't supported on this Mac."
        case .noAudioFormat: return "The speech model isn't ready yet."
        case .conversionFailed: return "The microphone audio couldn't be read."
        }
    }
}

/// Turns microphone buffers into the audio format the speech model wants.
final class BufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = buffer.format
        if source == format { return buffer }
        if converter == nil || converter?.inputFormat != source || converter?.outputFormat != format {
            converter = AVAudioConverter(from: source, to: format)
            // No priming, so the first words are not swallowed.
            converter?.primeMethod = .none
        }
        guard let converter else { throw SpeechEngineError.conversionFailed }

        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechEngineError.conversionFailed
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? SpeechEngineError.conversionFailed
        }
        return output
    }
}

/// Speech to text with Apple's on-device model (the Speech framework's SpeechAnalyzer).
/// Audio never leaves the Mac.
final class SpeechEngine {
    private let lock = NSLock()
    private var storedFormat: AVAudioFormat?

    /// The audio format the model wants. Known after `prepare` has run once.
    var analyzerFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return storedFormat
    }

    private func remember(_ format: AVAudioFormat?) {
        lock.lock()
        storedFormat = format
        lock.unlock()
    }

    /// English variants the on-device model supports, for example "en_IN" or "en_US".
    static func englishLocaleIdentifiers() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        let locales = await SpeechTranscriber.supportedLocales
        let english = locales.filter { $0.language.languageCode?.identifier == "en" }
        return english.map { $0.identifier }.sorted()
    }

    private func transcriberLocale(for identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw SpeechEngineError.unavailable }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
            return match
        }
        if let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return fallback
        }
        throw SpeechEngineError.languageNotSupported
    }

    func status(localeIdentifier: String) async -> SpeechModelStatus {
        do {
            let locale = try await transcriberLocale(for: localeIdentifier)
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            var status = await AssetInventory.status(forModules: [transcriber])
            if status == .supported, await isOnDisk(locale) {
                // The model is already on this Mac (another app or macOS fetched it). It only
                // has to be reserved for StupidTalk, which is quick and downloads nothing.
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try? await request.downloadAndInstall()
                }
                status = await AssetInventory.status(forModules: [transcriber])
            }
            switch status {
            case .installed: return .ready
            case .downloading: return .downloading(0)
            case .supported: return .needsDownload
            case .unsupported: return .unavailable("This language isn't supported on this Mac.")
            @unknown default: return .unknown
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func isOnDisk(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Downloads the speech model through macOS. `progress` gets values from 0 to 1.
    func install(localeIdentifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let locale = try await transcriberLocale(for: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { item, _ in
            progress(item.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Loads the model and learns its audio format, so a dictation can start without a pause.
    func prepare(localeIdentifier: String) async throws {
        let locale = try await transcriberLocale(for: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        remember(format)
        let options = SpeechAnalyzer.Options(priority: .utility, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.prepareToAnalyze(in: format)
    }

    /// Transcribes everything that arrives on `stream` and returns when the stream has finished.
    /// `vocabulary` nudges the recognizer toward your own words.
    func transcribe(stream: AsyncStream<AnalyzerInput>, localeIdentifier: String, vocabulary: [String]) async throws -> String {
        let locale = try await transcriberLocale(for: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            do {
                try await analyzer.setContext(context)
            } catch {
                Log.info("Word list hint was not accepted by the speech model: \(error.localizedDescription)")
            }
        }

        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }
}
