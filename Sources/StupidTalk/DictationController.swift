import AppKit
import AVFoundation
import Speech
import StupidTalkCore

/// Runs one dictation from start to finish:
/// hold the key, record, speech to text, clean up, paste at the cursor.
@MainActor
final class DictationController {
    private let state: AppState
    private let windows: WindowCoordinator
    private let hotkeys: HotkeyMonitor
    private let recorder = AudioRecorder()
    private let speech = SpeechEngine()
    private let cleaner = AICleaner()
    private let inserter = TextInserter()
    private let overlay: OverlayController
    private let converter = BufferConverter()

    private var current: Session?
    private var statusTimer: Timer?

    /// Everything that belongs to one press of the hold-to-talk key.
    private final class Session {
        let startedAt = Date()
        let targetApp: String?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var transcription: Task<String, Error>?
        /// The key came up (or the dictation was cancelled). No more audio is wanted.
        var released = false
        var cancelled = false

        init(targetApp: String?) {
            self.targetApp = targetApp
        }
    }

    init(state: AppState, windows: WindowCoordinator) {
        self.state = state
        self.windows = windows
        self.hotkeys = HotkeyMonitor(choice: state.hotkey)
        self.overlay = OverlayController()
    }

    // MARK: Start-up and status

    func start() {
        hotkeys.onAction = { [weak self] action in
            self?.handle(action)
        }
        hotkeys.start()
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        Task { @MainActor in
            await self.loadLocales()
            await self.prepareSpeech()
        }
    }

    /// Re-reads permissions and model availability. Cheap, so it runs every couple of seconds.
    func refreshStatus() {
        let wasGranted = state.accessibilityGranted
        let microphone = Permissions.microphone
        let accessibility = Permissions.accessibilityGranted
        if state.microphonePermission != microphone { state.microphonePermission = microphone }
        if state.accessibilityGranted != accessibility { state.accessibilityGranted = accessibility }
        if accessibility && !wasGranted {
            // Keyboard events from other apps only start flowing after a fresh registration.
            hotkeys.start()
            Log.info("Accessibility permission granted")
        }
        let ai = cleaner.status()
        if state.aiStatus != ai { state.aiStatus = ai }
        if hotkeys.choice != state.hotkey { hotkeys.choice = state.hotkey }
    }

    private func loadLocales() async {
        let identifiers = await SpeechEngine.englishLocaleIdentifiers()
        state.availableLocales = identifiers
    }

    /// Checks the speech model and loads it when it is installed.
    func prepareSpeech() async {
        let identifier = state.localeIdentifier
        let status = await speech.status(localeIdentifier: identifier)
        if case .downloading = state.speechStatus, case .downloading = status {
            return
        }
        state.speechStatus = status
        guard status == .ready else { return }
        do {
            try await speech.prepare(localeIdentifier: identifier)
        } catch {
            Log.info("Could not load the speech model: \(error.localizedDescription)")
        }
    }

    /// Downloads the on-device speech model through macOS.
    func installSpeechModel() {
        if case .downloading = state.speechStatus { return }
        state.speechStatus = .downloading(0)
        let identifier = state.localeIdentifier
        Task { @MainActor in
            do {
                try await self.speech.install(localeIdentifier: identifier) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.state.speechStatus {
                            self.state.speechStatus = .downloading(fraction)
                        }
                    }
                }
                self.state.speechStatus = .unknown
                await self.prepareSpeech()
            } catch {
                Log.info("Speech model download failed: \(error.localizedDescription)")
                self.state.speechStatus = .unavailable("The download didn't finish. Check your internet and try again.")
            }
        }
    }

    /// Call after the language setting changes.
    func languageChanged() {
        state.speechStatus = .unknown
        Task { @MainActor in
            await self.prepareSpeech()
        }
    }

    func requestMicrophone() {
        switch Permissions.microphone {
        case .granted:
            refreshStatus()
        case .notAsked:
            Permissions.requestMicrophone { _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatus()
                }
            }
        case .denied:
            Permissions.open(.microphone)
        }
    }

    func requestAccessibility() {
        if Permissions.accessibilityGranted {
            refreshStatus()
        } else {
            Permissions.promptForAccessibility()
            Permissions.open(.accessibility)
        }
    }

    // MARK: Menu actions

    func pasteLastResult() {
        guard let entry = state.lastEntry else { return }
        // Give the menu a moment to close so the paste lands in the app behind it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            let text = self.state.addTrailingSpace ? entry.cleaned + " " : entry.cleaned
            _ = self.inserter.insert(text, keepOnClipboard: self.state.keepOnClipboard)
        }
    }

    func copyLastResult(raw: Bool) {
        guard let entry = state.lastEntry else { return }
        inserter.copy(raw ? entry.raw : entry.cleaned)
    }

    func copy(_ text: String) {
        inserter.copy(text)
    }

    // MARK: The dictation itself

    private func handle(_ action: HoldToTalk.Action) {
        switch action {
        case .start: begin()
        case .finish: finish()
        case .cancel: cancel()
        case .none: break
        }
    }

    private func begin() {
        // Still busy with the previous dictation.
        guard current == nil else { return }

        guard Permissions.microphone == .granted else {
            problem("I need the microphone first.", openSetup: true)
            return
        }
        guard state.speechStatus == .ready else {
            problem("The speech model isn't ready yet.", openSetup: true)
            return
        }

        let session = Session(targetApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        current = session
        state.phase = .listening
        overlay.show(.listening)
        if state.playSounds { Sounds.start() }

        let words = state.vocabulary.words
        let locale = state.localeIdentifier
        let useAI = state.aiCleanupEnabled

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        session.continuation = continuation
        let speech = self.speech
        session.transcription = Task {
            try await speech.transcribe(stream: stream, localeIdentifier: locale, vocabulary: words)
        }
        if useAI {
            let cleaner = self.cleaner
            Task.detached(priority: .utility) {
                cleaner.warmUp(words: words)
            }
        }

        if let format = speech.analyzerFormat {
            startRecording(session, format: format)
        } else {
            // First dictation after launch, before the model finished loading.
            Task { @MainActor in
                do {
                    try await speech.prepare(localeIdentifier: locale)
                    guard let format = speech.analyzerFormat else { throw SpeechEngineError.noAudioFormat }
                    guard self.current === session, !session.released else { return }
                    self.startRecording(session, format: format)
                } catch {
                    self.fail(session, error: error)
                }
            }
        }
    }

    private func startRecording(_ session: Session, format: AVAudioFormat) {
        guard let continuation = session.continuation else { return }
        let converter = self.converter
        let model = overlay.model
        recorder.start(
            preferBuiltInMicrophone: state.microphone == .builtIn,
            onBuffer: { buffer in
                if let converted = try? converter.convert(buffer, to: format) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            },
            onLevel: { level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        model.push(level)
                    }
                }
            },
            completion: { error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.fail(session, error: error)
                }
            }
        )
    }

    private func finish() {
        guard let session = current, !session.released else { return }
        session.released = true
        state.phase = .transcribing
        overlay.show(.thinking)
        recorder.stop {
            Task { @MainActor [weak self] in
                session.continuation?.finish()
                self?.process(session)
            }
        }
    }

    private func cancel() {
        guard let session = current, !session.released else { return }
        session.released = true
        session.cancelled = true
        recorder.stop {
            Task { @MainActor in
                session.continuation?.finish()
                session.transcription?.cancel()
            }
        }
        overlay.hide()
        end(session)
    }

    private func process(_ session: Session) {
        guard !session.cancelled, let transcription = session.transcription else {
            end(session)
            return
        }
        Task { @MainActor in
            do {
                let heard: String = try await Race.withTimeout(seconds: 45) {
                    try await transcription.value
                }
                let raw = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    self.overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
                    self.end(session)
                    return
                }

                let vocabulary = self.state.vocabulary
                let prepared = CleanupPipeline.prepare(raw: raw, vocabulary: vocabulary)
                let piece: CleanupPipeline.Piece
                if self.state.aiCleanupEnabled, self.cleaner.status().isReady, CleanupPipeline.wantsAI(prepared) {
                    self.state.phase = .cleaning
                    self.overlay.show(.cleaning("Cleaning up"))
                    let overlay = self.overlay
                    piece = await self.cleaner.clean(prepared: prepared, vocabulary: vocabulary) { index, count in
                        guard count > 1 else { return }
                        Task { @MainActor in
                            overlay.show(.cleaning("Cleaning up \(index) of \(count)"))
                        }
                    }
                } else {
                    piece = CleanupPipeline.Piece(text: CleanupPipeline.ruleCleaned(prepared, vocabulary: vocabulary), usedAI: false)
                }
                self.deliver(piece, raw: raw, session: session)
            } catch {
                self.fail(session, error: error)
            }
        }
    }

    private func deliver(_ piece: CleanupPipeline.Piece, raw: String, session: Session) {
        guard !piece.text.isEmpty else {
            overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
            end(session)
            return
        }
        let seconds = Date().timeIntervalSince(session.startedAt)
        let text = state.addTrailingSpace ? piece.text + " " : piece.text
        let result = inserter.insert(text, keepOnClipboard: state.keepOnClipboard)
        state.record(HistoryEntry(raw: raw, cleaned: piece.text, usedAI: piece.usedAI, appName: session.targetApp, seconds: seconds))

        let words = Words.count(piece.text)
        if let note = piece.note {
            Log.info("Dictation done: \(words) words in \(String(format: "%.1f", seconds))s, rule-based clean-up (\(note))")
        } else {
            Log.info("Dictation done: \(words) words in \(String(format: "%.1f", seconds))s, \(piece.usedAI ? "AI clean-up" : "rule-based clean-up")")
        }

        switch result {
        case .pasted:
            if state.playSounds { Sounds.done() }
            overlay.flash(.done, seconds: 0.9)
        case .copiedOnly:
            overlay.flash(.message("Copied. Press \u{2318}V to paste.", .point), seconds: 3)
        }
        end(session)
    }

    private func fail(_ session: Session, error: Error) {
        Log.info("Dictation failed: \(error.localizedDescription)")
        session.released = true
        session.cancelled = true
        recorder.stop {
            Task { @MainActor in
                session.continuation?.finish()
                session.transcription?.cancel()
            }
        }
        // Only an error that comes from macOS's speech system itself can be a permission problem.
        let ownError = error is RecorderError || error is SpeechEngineError || error is Race.TimedOut || error is CancellationError
        if !ownError, let message = speechPermissionMessage() {
            problem(message, openSetup: false)
        } else {
            problem(DictationController.friendly(error), openSetup: false)
        }
        end(session)
    }

    /// On-device speech normally needs no extra permission. If macOS wants the Speech
    /// Recognition permission after all, ask for it the first time a dictation fails.
    private func speechPermissionMessage() -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in }
            return "Allow speech recognition, then try again."
        case .denied, .restricted:
            Permissions.open(.speechRecognition)
            return "Speech recognition is switched off for StupidTalk."
        default:
            return nil
        }
    }

    private func problem(_ message: String, openSetup: Bool) {
        if state.playSounds { Sounds.problem() }
        overlay.flash(.message(message, .confused), seconds: 2.6)
        if openSetup { windows.showSetup() }
    }

    private func end(_ session: Session) {
        if current === session { current = nil }
        state.phase = .idle
    }

    private static func friendly(_ error: Error) -> String {
        if let recorder = error as? RecorderError, let text = recorder.errorDescription { return text }
        if let speech = error as? SpeechEngineError, let text = speech.errorDescription { return text }
        if error is Race.TimedOut { return "That took too long. Try again." }
        if error is CancellationError { return "Cancelled." }
        return "Something went wrong. Try again."
    }
}
