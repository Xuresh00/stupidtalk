import AppKit
import Combine
import StupidTalkCore

enum MicrophoneChoice: String, CaseIterable {
    case builtIn
    case systemDefault

    var title: String {
        switch self {
        case .builtIn: return "This Mac's microphone"
        case .systemDefault: return "System default"
        }
    }
}

enum DictationPhase: Equatable {
    case idle
    case listening
    case transcribing
    case cleaning
}

/// When the on-device model is asked to help.
enum AIMode: String, CaseIterable {
    /// Rules do the clean-up at once. The model only looks at a self-correction the rules are unsure about.
    case smart
    /// The model rewrites every dictation. More polish, more waiting.
    case always

    var title: String {
        switch self {
        case .smart: return "Only when I correct myself"
        case .always: return "On every dictation"
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case cleanup = "Clean-up"
    case words = "Word list"
    case history = "History"
    case about = "About"
}

/// Everything the windows and the menu show: your settings plus what is going on right now.
@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let hotkey = "hotkey"
        static let aiCleanup = "aiCleanupEnabled"
        static let aiMode = "aiMode"
        static let microphone = "microphone"
        static let locale = "localeIdentifier"
        static let keepOnClipboard = "keepOnClipboard"
        static let trailingSpace = "addTrailingSpace"
        static let sounds = "playSounds"
        static let saveHistory = "saveHistory"
        static let setupFinished = "setupFinished"
        static let totalWords = "totalWords"
    }

    private let defaults = UserDefaults.standard
    private let historyStore: HistoryStore
    private let vocabularyURL: URL

    // Settings. Each one saves itself when it changes.
    @Published var hotkey: HotkeyChoice {
        didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) }
    }
    @Published var aiCleanupEnabled: Bool {
        didSet { defaults.set(aiCleanupEnabled, forKey: Keys.aiCleanup) }
    }
    @Published var aiMode: AIMode {
        didSet { defaults.set(aiMode.rawValue, forKey: Keys.aiMode) }
    }
    @Published var microphone: MicrophoneChoice {
        didSet { defaults.set(microphone.rawValue, forKey: Keys.microphone) }
    }
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Keys.locale) }
    }
    @Published var keepOnClipboard: Bool {
        didSet { defaults.set(keepOnClipboard, forKey: Keys.keepOnClipboard) }
    }
    @Published var addTrailingSpace: Bool {
        didSet { defaults.set(addTrailingSpace, forKey: Keys.trailingSpace) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.sounds) }
    }
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Keys.saveHistory) }
    }
    @Published var setupFinished: Bool {
        didSet { defaults.set(setupFinished, forKey: Keys.setupFinished) }
    }
    @Published var vocabulary: Vocabulary {
        didSet { VocabularyFile.save(vocabulary, to: vocabularyURL) }
    }

    // Saved results.
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var lastEntry: HistoryEntry?
    @Published private(set) var totalWords: Int
    /// Seconds between letting go of the key and the text being typed, for the latest dictation.
    @Published private(set) var lastWait: Double?

    // What is going on right now.
    @Published var phase: DictationPhase = .idle
    @Published var microphonePermission: MicrophonePermission = .notAsked
    @Published var accessibilityGranted = false
    @Published var speechStatus: SpeechModelStatus = .unknown
    @Published var aiStatus: AIStatus = .off("Checking")
    @Published var availableLocales: [String] = []
    @Published var settingsTab: SettingsTab = .general

    init() {
        let support = AppInfo.supportDirectory
        vocabularyURL = support.appendingPathComponent("word-list.json")
        historyStore = HistoryStore(fileURL: support.appendingPathComponent("history.json"), limit: 200)

        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: Keys.hotkey) ?? "") ?? .rightOption
        aiCleanupEnabled = defaults.object(forKey: Keys.aiCleanup) as? Bool ?? true
        aiMode = AIMode(rawValue: defaults.string(forKey: Keys.aiMode) ?? "") ?? .smart
        microphone = MicrophoneChoice(rawValue: defaults.string(forKey: Keys.microphone) ?? "") ?? .builtIn
        localeIdentifier = defaults.string(forKey: Keys.locale) ?? AppState.defaultLocaleIdentifier()
        keepOnClipboard = defaults.object(forKey: Keys.keepOnClipboard) as? Bool ?? false
        addTrailingSpace = defaults.object(forKey: Keys.trailingSpace) as? Bool ?? true
        playSounds = defaults.object(forKey: Keys.sounds) as? Bool ?? false
        saveHistory = defaults.object(forKey: Keys.saveHistory) as? Bool ?? true
        setupFinished = defaults.bool(forKey: Keys.setupFinished)
        totalWords = defaults.integer(forKey: Keys.totalWords)

        if let saved = VocabularyFile.load(from: vocabularyURL) {
            vocabulary = saved
        } else {
            vocabulary = Vocabulary.starter
            VocabularyFile.save(Vocabulary.starter, to: vocabularyURL)
        }
        entries = historyStore.entries
        lastEntry = historyStore.entries.first
        microphonePermission = Permissions.microphone
        accessibilityGranted = Permissions.accessibilityGranted
    }

    /// English as set on this Mac when possible ("en_IN" in India), otherwise US English.
    static func defaultLocaleIdentifier() -> String {
        let current = Locale.current
        if current.language.languageCode?.identifier == "en" {
            return current.identifier
        }
        return "en_US"
    }

    var everythingReady: Bool {
        microphonePermission == .granted && accessibilityGranted && speechStatus == .ready
    }

    /// Stores a finished dictation. The latest one is always kept in memory so it can be
    /// pasted again, even when saving history is switched off.
    func record(_ entry: HistoryEntry) {
        lastEntry = entry
        lastWait = entry.wait
        totalWords += Words.count(entry.cleaned)
        defaults.set(totalWords, forKey: Keys.totalWords)
        if saveHistory {
            historyStore.add(entry)
            entries = historyStore.entries
        }
    }

    func removeEntry(_ id: UUID) {
        historyStore.remove(id: id)
        entries = historyStore.entries
    }

    func clearHistory() {
        historyStore.clear()
        entries = []
    }

    func addWord() {
        vocabulary.entries.append(VocabularyEntry(word: "", soundsLike: []))
    }

    func removeWord(_ id: UUID) {
        vocabulary.entries.removeAll { $0.id == id }
    }

    func updateWord(_ id: UUID, word: String? = nil, soundsLike: [String]? = nil) {
        guard let index = vocabulary.entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = vocabulary.entries[index]
        if let word { entry.word = word }
        if let soundsLike { entry.soundsLike = soundsLike }
        guard entry != vocabulary.entries[index] else { return }
        vocabulary.entries[index] = entry
    }
}
