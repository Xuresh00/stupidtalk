import AppKit
import AVFoundation
import Speech
import StupidTalkCore

/// Runs one dictation from start to finish:
/// hold the key, record, speech to text, clean up, paste at the cursor.
///
/// Speed comes first. The text is typed as soon as it has been heard and tidied by rule.
/// The on-device model is only asked when you corrected yourself in a way the rules are
/// not sure about, and it always has a time limit.
@MainActor
final class DictationController {
    /// How long the model may take for one unsure self-correction before the rule-based text is typed.
    private static let smartBudget = 2.0

    /// How long the model may polish a dictation of this many words before the rule-based text is typed.
    /// A sentence or two gets 2 seconds at most. Usually it needs well under one.
    private static func polishBudget(words: Int) -> Double {
        min(4.0, 1.5 + 0.015 * Double(words))
    }

    /// The "allow Accessibility" hint opens the setup window only once per launch.
    private var askedForAccessibility = false

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
    private var releaseTimer: Timer?
    private var ticks = 0

    /// Everything that belongs to one press of the hold-to-talk key.
    private final class Session {
        let startedAt = Date()
        let targetApp: String?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var transcription: Task<String, Error>?
        /// The key came up (or the dictation was cancelled). No more audio is wanted.
        var released = false
        var cancelled = false
        var releasedAt: Date?
        /// Keeps macOS from slowing the app down while a dictation is running.
        var activity: NSObjectProtocol?
        /// For the safety net that notices a key release macOS did not report.
        var sawKeyDown = false
        var missedPolls = 0

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
        warmUpAI(speedTest: true)
    }

    /// Re-reads permissions. Cheap, so it runs every couple of seconds.
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
        // The on-device model is asked about in the background, never here on the main thread.
        ticks += 1
        if ticks % 15 == 0 { refreshAIStatus() }
        let ai = cleaner.status
        if state.aiStatus != ai { state.aiStatus = ai }
        if hotkeys.choice != state.hotkey { hotkeys.choice = state.hotkey }
    }

    private func refreshAIStatus() {
        let cleaner = self.cleaner
        Task.detached(priority: .utility) {
            cleaner.refreshStatus()
        }
    }

    /// Gets the on-device model loaded in the background so it is ready when it is needed.
    private func warmUpAI(speedTest: Bool = false) {
        guard state.aiCleanupEnabled else {
            refreshAIStatus()
            return
        }
        let cleaner = self.cleaner
        let words = state.vocabulary.words
        Task.detached(priority: .userInitiated) {
            if speedTest {
                // Let the app finish starting first.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                cleaner.refreshStatus()
                await cleaner.warmUpWithSample(words: words)
            }
            cleaner.warmUp(words: words)
        }
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
        guard status == .ready else {
            Log.info("Speech model is not ready")
            return
        }
        do {
            let started = Date()
            try await speech.prepare(localeIdentifier: identifier)
            Log.info("Speech model loaded in \(Self.ms(since: started)) ms")
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
            Permissions.requestMicrophone { [weak self] _ in
                Task { @MainActor in
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

    /// Puts the latest timings on the clipboard. It holds numbers only, never what was said.
    func copySpeedReport() {
        var lines = ["StupidTalk \(AppInfo.version) speed report"]
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Key: \(state.hotkey.shortTitle). AI clean-up: \(state.aiCleanupEnabled ? state.aiMode.title : "off"). Model: \(state.aiStatus.isReady ? "ready" : "not ready").")
        if let problem = Log.problem {
            lines.append("The log file could not be written: \(problem)")
        }
        lines.append("")
        lines.append(contentsOf: Log.recent)
        inserter.copy(lines.joined(separator: "\n"))
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
        guard current == nil else {
            Log.info("Key pressed while the last dictation was still being typed")
            return
        }

        guard Permissions.microphone == .granted else {
            Log.info("Key pressed, but the microphone is not allowed yet")
            problem("I need the microphone first.", openSetup: true)
            return
        }
        guard state.speechStatus == .ready else {
            Log.info("Key pressed, but the speech model is not ready")
            problem("The speech model isn't ready yet.", openSetup: true)
            return
        }

        let session = Session(targetApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        // A menu bar app with no window is the first thing macOS slows down. Not during a dictation.
        session.activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Dictation"
        )
        current = session
        state.phase = .listening
        overlay.show(.listening)
        if state.playSounds { Sounds.start() }
        Log.info("Listening")

        let words = state.vocabulary.words
        let locale = state.localeIdentifier

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        session.continuation = continuation
        let speech = self.speech
        session.transcription = Task(priority: .userInitiated) {
            try await speech.transcribe(stream: stream, localeIdentifier: locale, vocabulary: words)
        }
        // Have the model loaded by the time you stop talking, in case it is needed.
        warmUpAI()
        watchForRelease(session)

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
            completion: { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.fail(session, error: error)
                }
            }
        )
    }

    /// Safety net: if macOS never reports the key coming up, notice it by asking for the key's state.
    private func watchForRelease(_ session: Session) {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkRelease(session)
            }
        }
    }

    private func stopWatchingForRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    private func checkRelease(_ session: Session) {
        guard current === session, !session.released else {
            stopWatchingForRelease()
            return
        }
        if hotkeys.isKeyDown() {
            session.sawKeyDown = true
            session.missedPolls = 0
            return
        }
        // Only trust "the key is up" on keyboards where "the key is down" was seen first.
        guard session.sawKeyDown else { return }
        session.missedPolls += 1
        guard session.missedPolls >= 3 else { return }
        Log.info("macOS did not report the key release. Noticed it by checking the key.")
        hotkeys.forgetHold()
        finish()
    }

    private func finish() {
        guard let session = current, !session.released else { return }
        session.released = true
        session.releasedAt = Date()
        stopWatchingForRelease()
        state.phase = .transcribing
        overlay.show(.thinking)
        recorder.stop { [weak self] in
            Task { @MainActor in
                session.continuation?.finish()
                self?.process(session)
            }
        }
    }

    private func cancel() {
        guard let session = current, !session.released else { return }
        session.released = true
        session.cancelled = true
        stopWatchingForRelease()
        Log.info("Cancelled")
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
        Task(priority: .userInitiated) { @MainActor in
            do {
                let heard: String = try await Race.withTimeout(seconds: 45) {
                    try await transcription.value
                }
                let heardAt = Date()
                let raw = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    Log.info("Heard nothing. \(self.timing(session, heardAt: heardAt))")
                    self.overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
                    self.end(session)
                    return
                }

                // The fast path: word list, self-corrections the rules are sure about, fillers, punctuation.
                let vocabulary = self.state.vocabulary
                let prepared = CleanupPipeline.prepare(raw: raw, vocabulary: vocabulary)
                let plan = CleanupPipeline.plan(prepared: prepared, vocabulary: vocabulary)
                var piece = CleanupPipeline.Piece(text: plan.ruleText, usedAI: false)
                var how = plan.repairs > 0 ? "rules (\(plan.repairs) self-correction fixed)" : "rules"

                let modelReady = self.state.aiCleanupEnabled && self.cleaner.status.isReady
                if modelReady, self.state.aiMode == .always, CleanupPipeline.wantsPolish(plan.ruleText) {
                    self.state.phase = .cleaning
                    self.overlay.show(.cleaning("Cleaning up"))
                    let started = Date()
                    let budget = Self.polishBudget(words: Words.count(plan.ruleText))
                    piece = await self.cleaner.polish(ruleText: plan.ruleText, vocabulary: vocabulary, budget: budget)
                    how = "AI polish on \(Words.count(plan.ruleText)) words, \(Self.ms(since: started)) ms"
                } else if modelReady, let window = plan.window {
                    self.state.phase = .cleaning
                    self.overlay.show(.cleaning("Cleaning up"))
                    let started = Date()
                    let reply = await self.cleaner.answer(for: window.middle, words: vocabulary.words, budget: Self.smartBudget)
                    piece = CleanupPipeline.finish(plan: plan, modelOutput: reply, vocabulary: vocabulary)
                    how = "AI on \(Words.count(window.middle)) words, \(Self.ms(since: started)) ms"
                } else if plan.window != nil {
                    how += ", one correction left as said"
                }
                self.deliver(piece, raw: raw, session: session, heardAt: heardAt, how: how)
            } catch {
                self.fail(session, error: error)
            }
        }
    }

    private func deliver(_ piece: CleanupPipeline.Piece, raw: String, session: Session, heardAt: Date, how: String) {
        guard !piece.text.isEmpty else {
            Log.info("Nothing left to type after the clean-up. \(timing(session, heardAt: heardAt))")
            overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
            end(session)
            return
        }
        let text = state.addTrailingSpace ? piece.text + " " : piece.text
        let result = inserter.insert(text, keepOnClipboard: state.keepOnClipboard)
        let typedAt = Date()
        let wait = typedAt.timeIntervalSince(session.releasedAt ?? typedAt)
        state.record(HistoryEntry(
            raw: raw,
            cleaned: piece.text,
            usedAI: piece.usedAI,
            appName: session.targetApp,
            seconds: typedAt.timeIntervalSince(session.startedAt),
            wait: wait
        ))

        var line = "Typed \(Words.count(piece.text)) words \(Self.ms(wait)) ms after the key came up. "
        line += timing(session, heardAt: heardAt)
        line += " Clean-up: \(how)."
        if let note = piece.note { line += " Model answer not used: \(note)." }
        if result == .copiedOnly { line += " Only copied, Accessibility is missing." }
        Log.info(line)

        switch result {
        case .pasted:
            if state.playSounds { Sounds.done() }
            overlay.flash(.done, seconds: 0.9)
        case .copiedOnly:
            // macOS has not allowed StupidTalk to paste. The text is on the clipboard meanwhile.
            overlay.flash(.message("Copied. Allow Accessibility so I can paste for you.", .point), seconds: 3.5)
            if !askedForAccessibility {
                askedForAccessibility = true
                Permissions.promptForAccessibility()
                windows.showSetup()
            }
        }
        end(session)
        // Load a fresh model session for the next time.
        warmUpAI()
    }

    private func fail(_ session: Session, error: Error) {
        Log.info("Dictation failed: \(error.localizedDescription)")
        session.released = true
        session.cancelled = true
        stopWatchingForRelease()
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
        if let activity = session.activity {
            ProcessInfo.processInfo.endActivity(activity)
            session.activity = nil
        }
        if current === session {
            current = nil
            stopWatchingForRelease()
        }
        state.phase = .idle
    }

    // MARK: Timing, for the log

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func ms(since start: Date) -> Int {
        ms(Date().timeIntervalSince(start))
    }

    /// "Talked 4.2 s, heard 310 ms after the key came up."
    private func timing(_ session: Session, heardAt: Date) -> String {
        let released = session.releasedAt ?? heardAt
        let talked = String(format: "%.1f", released.timeIntervalSince(session.startedAt))
        return "Talked \(talked) s, heard \(Self.ms(heardAt.timeIntervalSince(released))) ms after the key came up."
    }

    private static func friendly(_ error: Error) -> String {
        if let recorder = error as? RecorderError, let text = recorder.errorDescription { return text }
        if let speech = error as? SpeechEngineError, let text = speech.errorDescription { return text }
        if error is Race.TimedOut { return "That took too long. Try again." }
        if error is CancellationError { return "Cancelled." }
        return "Something went wrong. Try again."
    }
}
