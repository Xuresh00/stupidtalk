import AppKit
import AVFoundation
import StupidTalkCore

/// Runs one dictation from start to finish:
/// hold the key, record, speech to text on this Mac, tidy up, type it at the cursor.
///
/// Speed comes first. The words are typed as soon as they have been heard and tidied by rule.
/// The optional AI polish is off unless you switch it on, and it always has a time limit.
@MainActor
final class DictationController {
    /// How long the model may take for one unsure self-correction before the rule-based text is typed.
    private static let smartBudget = 2.0

    /// How long the model may polish a dictation of this many words before the rule-based text is typed.
    /// A sentence or two gets 2 seconds at most. Usually it needs well under one.
    private static func polishBudget(words: Int) -> Double {
        min(4.0, 1.5 + 0.015 * Double(words))
    }

    /// People let go of the key a moment before the last word is finished.
    /// The microphone keeps listening this long after the key comes up.
    private static let tailSeconds = 0.35

    /// How long the Copy button stays in the pill after the words are typed.
    private static let copySeconds = 2.0

    /// The "allow Accessibility" hint opens the setup window only once per launch.
    private var askedForAccessibility = false

    private let state: AppState
    private let windows: WindowCoordinator
    private let hotkeys: HotkeyMonitor
    private let recorder = AudioRecorder()
    private let engine = SpeechEngine()
    private let models = ModelStore()
    private let cleaner = AICleaner()
    private let inserter = TextInserter()
    private let overlay: OverlayController

    private var current: Session?
    private var statusTimer: Timer?
    private var releaseTimer: Timer?
    private var ticks = 0

    /// Everything that belongs to one press of the hold-to-talk key.
    private final class Session {
        let startedAt = Date()
        let targetApp: String?
        /// Your voice, as 16 kHz samples, filled in while you hold the key.
        let samples = SampleCollector()
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
        overlay.copyHandler = { [weak self] text in
            self?.inserter.copy(text)
            Log.info("Copied the latest dictation from the pill")
        }
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        ModelStore.removeLeftovers()
        Task { @MainActor in
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
        syncMicrophone()
        // The on-device model is asked about in the background, never here on the main thread.
        ticks += 1
        if ticks % 15 == 0 { refreshAIStatus() }
        let ai = cleaner.status
        if state.aiStatus != ai { state.aiStatus = ai }
        if hotkeys.choice != state.hotkey { hotkeys.choice = state.hotkey }
    }

    /// With Instant start the microphone is kept open between dictations. This also opens it
    /// again after a device change or a wake from sleep, because it runs every couple of seconds.
    private func syncMicrophone() {
        guard current == nil else { return }
        if state.instantStart && Permissions.microphone == .granted {
            recorder.warmUp(preferBuiltInMicrophone: state.microphone == .builtIn)
        } else {
            recorder.coolDown()
        }
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

    /// Loads the chosen speech model onto the GPU when it is downloaded.
    func prepareSpeech() async {
        let choice = state.speechModel
        if models.downloading == choice { return }
        guard ModelStore.isInstalled(choice) else {
            state.speechStatus = .needsDownload
            Log.info("Speech model \(choice.rawValue) is not downloaded yet")
            return
        }
        state.speechStatus = .loading
        let started = Date()
        do {
            let backend = try await engine.load(ModelStore.fileURL(for: choice))
            guard state.speechModel == choice else { return }
            state.speechStatus = .ready
            Log.info("Speech model \(choice.rawValue) loaded on \(backend) in \(Self.ms(since: started)) ms")
        } catch {
            guard state.speechModel == choice else { return }
            Log.info("Could not load the speech model: \(error)")
            state.speechStatus = .unavailable(SpeechEngine.plainMessage(for: error))
        }
    }

    /// Downloads the chosen speech model. The only download StupidTalk ever makes.
    func downloadSpeechModel() {
        let choice = state.speechModel
        if models.downloading == choice { return }
        state.speechStatus = .downloading(0)
        Log.info("Downloading speech model \(choice.rawValue)")
        let started = Date()
        models.download(choice, progress: { [weak self] fraction in
            MainActor.assumeIsolated {
                guard let self, self.state.speechModel == choice, case .downloading = self.state.speechStatus else { return }
                self.state.speechStatus = .downloading(fraction)
            }
        }, completion: { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success:
                    Log.info("Speech model downloaded and checked in \(Int(Date().timeIntervalSince(started))) s")
                    guard self.state.speechModel == choice else { return }
                    Task { @MainActor in
                        await self.prepareSpeech()
                    }
                case .failure(let error):
                    Log.info("Speech model download failed: \(error.localizedDescription)")
                    guard self.state.speechModel == choice else { return }
                    self.state.speechStatus = .unavailable("The download didn't finish. Check your internet and try again.")
                }
            }
        })
    }

    /// Throws the model file away and downloads it again. For a file that will not load.
    func redownloadSpeechModel() {
        engine.unload()
        ModelStore.remove(state.speechModel)
        downloadSpeechModel()
    }

    /// Call after the speech model setting changes.
    func speechModelChanged() {
        if let other = models.downloading, other != state.speechModel {
            models.cancel()
        }
        engine.unload()
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

    func typeLastResult() {
        guard let entry = state.lastEntry else { return }
        // Give the menu a moment to close so the words land in the app behind it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            let text = self.state.addTrailingSpace ? entry.cleaned + " " : entry.cleaned
            if await self.inserter.insert(text, method: self.state.insertMethod) == .needsAccessibility {
                self.problem("Allow Accessibility so I can type for you.", openSetup: true)
            }
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
        lines.append("Key: \(state.hotkey.shortTitle). Speech model: \(state.speechModel.rawValue) (\(state.speechStatus == .ready ? "ready" : "not ready")). Typing: \(state.insertMethod.rawValue).")
        lines.append("AI polish: \(state.aiCleanupEnabled ? state.aiMode.title : "off"). Apple model: \(state.aiStatus.isReady ? "ready" : "not ready").")
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
        switch state.speechStatus {
        case .ready:
            break
        case .downloading(let fraction):
            problem("Still downloading the speech model (\(Int(fraction * 100))%).", openSetup: false)
            return
        case .loading:
            problem("One moment, the speech model is still loading.", openSetup: false)
            return
        default:
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

        // Have the optional AI loaded by the time you stop talking, in case it is needed.
        warmUpAI()
        watchForRelease(session)
        startRecording(session)
    }

    private func startRecording(_ session: Session) {
        let model = overlay.model
        recorder.start(
            preferBuiltInMicrophone: state.microphone == .builtIn,
            into: session.samples,
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
        recorder.stop(tail: Self.tailSeconds, keepOpen: state.instantStart) { [weak self] in
            Task { @MainActor in
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
        recorder.stop(keepOpen: state.instantStart) {}
        overlay.hide()
        end(session)
    }

    private func process(_ session: Session) {
        guard !session.cancelled else {
            end(session)
            return
        }
        let samples = session.samples.snapshot()
        let words = state.vocabulary.words
        let engine = self.engine
        Task(priority: .userInitiated) { @MainActor in
            guard let range = AudioTrim.speechRange(samples) else {
                Log.info("Heard only silence. \(self.timing(session, heardAt: Date()))")
                self.overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
                self.end(session)
                return
            }
            let clip = Array(samples[range])
            do {
                let heard = try await Race.withTimeout(seconds: 45) {
                    try await engine.transcribe(clip, vocabulary: words)
                }
                let heardAt = Date()
                let raw = heard.text
                guard !raw.isEmpty else {
                    Log.info("Heard nothing. \(self.timing(session, heardAt: heardAt))")
                    self.overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
                    self.end(session)
                    return
                }
                let speech = "speech \(heard.milliseconds) ms for \(String(format: "%.1f", Double(clip.count) / 16_000)) s of audio"

                // The fast path: word list, self-corrections the rules are sure about, fillers.
                // Nothing here adds commas, brackets or lists of its own.
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
                await self.deliver(piece, raw: raw, session: session, heardAt: heardAt, how: how + ", " + speech)
            } catch {
                self.fail(session, error: error)
            }
        }
    }

    private func deliver(_ piece: CleanupPipeline.Piece, raw: String, session: Session, heardAt: Date, how: String) async {
        guard !piece.text.isEmpty else {
            Log.info("Nothing left to type after the clean-up. \(timing(session, heardAt: heardAt))")
            overlay.flash(.message("I didn't catch that.", .confused), seconds: 1.6)
            end(session)
            return
        }
        let text = state.addTrailingSpace ? piece.text + " " : piece.text
        let method = state.insertMethod
        let result = await inserter.insert(text, method: method)
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

        var line = "Typed \(Words.count(piece.text)) words (\(method.rawValue)) \(Self.ms(wait)) ms after the key came up. "
        line += timing(session, heardAt: heardAt)
        line += " Clean-up: \(how)."
        if let note = piece.note { line += " Model answer not used: \(note)." }
        if result == .needsAccessibility { line += " Not typed, Accessibility is missing." }
        Log.info(line)

        switch result {
        case .inserted:
            if state.playSounds { Sounds.done() }
            // Your clipboard is untouched. The button is there if you want the words on it too.
            overlay.offerCopy(piece.text, seconds: Self.copySeconds)
        case .needsAccessibility:
            overlay.offerCopy(piece.text, note: "Allow Accessibility so I can type for you.", seconds: 6)
            if !askedForAccessibility {
                askedForAccessibility = true
                Permissions.promptForAccessibility()
                windows.showSetup()
            }
        }
        end(session)
        // Load a fresh AI session for the next time, when the AI polish is on.
        warmUpAI()
    }

    private func fail(_ session: Session, error: Error) {
        Log.info("Dictation failed: \(error.localizedDescription)")
        session.released = true
        session.cancelled = true
        stopWatchingForRelease()
        recorder.stop(keepOpen: state.instantStart) {}
        problem(Self.friendly(error), openSetup: false)
        end(session)
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
        if error is Race.TimedOut { return "That took too long. Try again." }
        if error is CancellationError { return "Cancelled." }
        return SpeechEngine.plainMessage(for: error)
    }
}
