import AppKit
import ServiceManagement
import StupidTalkCore
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.info("Open at login could not be changed: \(error.localizedDescription)")
            return false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    let controller: DictationController
    @LocalState private var openAtLogin = LoginItem.isEnabled

    init(state: AppState, controller: DictationController) {
        self.state = state
        self.controller = controller
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Brand.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    page
                }
                .padding(.horizontal, 26)
                .padding(.top, 34)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .background(Brand.ink)
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                OopsView(pose: .rock)
                    .frame(width: 34, height: 46)
                Text("StupidTalk")
                    .font(Brand.display(16))
                    .foregroundStyle(Brand.cream)
            }
            .padding(.bottom, 16)

            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    state.settingsTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(Brand.textMedium(14))
                        .foregroundStyle(state.settingsTab == tab ? Brand.ink : Brand.cream)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(state.settingsTab == tab ? Brand.amber : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(AppInfo.tagline)
                .font(Brand.text(12))
                .foregroundStyle(Brand.faint)
            Text("by Stupidesigner")
                .font(Brand.textMedium(12))
                .foregroundStyle(Brand.muted)
        }
        .padding(.top, 46)
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(width: 210)
        .background(Brand.surface)
    }

    @ViewBuilder
    private var page: some View {
        switch state.settingsTab {
        case .general: generalPage
        case .cleanup: cleanupPage
        case .words: wordsPage
        case .history: historyPage
        case .about: aboutPage
        }
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Brand.display(24))
                .foregroundStyle(Brand.cream)
            Text(subtitle)
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func switchControl(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value)
            .labelsHidden()
            .toggleStyle(.switch)
    }

    // MARK: General

    @ViewBuilder
    private var generalPage: some View {
        title("General", "Hold the key, talk, let go. The text lands where your cursor is.")

        Card {
            SettingRow("Hold-to-talk key", detail: "Hold it while you speak. A quick tap does nothing, and pressing any other key cancels.") {
                Picker("", selection: $state.hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
            }
            if state.hotkey == .fn {
                Divide()
                SettingRow("One more step for the Fn key", detail: "In Keyboard settings, set \"Press Globe key to\" to \"Do Nothing\". Otherwise macOS also opens the emoji picker.") {
                    Button("Open Keyboard settings") {
                        Permissions.open(.keyboard)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .onChange(of: state.hotkey) { _, _ in
            controller.refreshStatus()
        }

        Card {
            SettingRow("Microphone", detail: "This Mac's microphone keeps AirPods in music quality and starts faster. Pick System default for an external mic.") {
                Picker("", selection: $state.microphone) {
                    ForEach(MicrophoneChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
            }
            Divide()
            SettingRow("English accent", detail: "Pick the English you speak. It helps the speech model hear you right.") {
                Picker("", selection: $state.localeIdentifier) {
                    ForEach(localeChoices, id: \.self) { identifier in
                        Text(localeName(identifier)).tag(identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 210)
            }
        }
        .onChange(of: state.localeIdentifier) { _, _ in
            controller.languageChanged()
        }

        Card {
            SettingRow("Add a space after each dictation", detail: "So the next sentence doesn't stick to the last one.") {
                switchControl($state.addTrailingSpace)
            }
            Divide()
            SettingRow("Keep the text on the clipboard", detail: "Off: your old clipboard comes back after the paste.") {
                switchControl($state.keepOnClipboard)
            }
            Divide()
            SettingRow("Play sounds", detail: "A small sound when listening starts and when the text is typed.") {
                switchControl($state.playSounds)
            }
            Divide()
            SettingRow("Open at login", detail: "Start StupidTalk when you sign in to your Mac.") {
                switchControl(Binding(
                    get: { openAtLogin },
                    set: { wanted in
                        LoginItem.set(wanted)
                        openAtLogin = LoginItem.isEnabled
                    }
                ))
            }
        }
    }

    private var localeChoices: [String] {
        var choices = state.availableLocales
        if !choices.contains(state.localeIdentifier) {
            choices.insert(state.localeIdentifier, at: 0)
        }
        return choices
    }

    private func localeName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: Clean-up

    @ViewBuilder
    private var cleanupPage: some View {
        title("Clean-up", "Mr. Oops tidies what you said before he types it. It all happens on this Mac.")

        Card {
            SettingRow("AI clean-up", detail: "The on-device model makes lists, adds brackets, fixes small grammar mistakes and punctuation. Switch it off and only the instant, rule-based clean-up runs.") {
                switchControl($state.aiCleanupEnabled)
            }
            Divide()
            SettingRow("When to use the AI", detail: "On every dictation: lists, brackets and grammar get fixed. It usually takes well under a second, and never more than about 2 for a sentence or two. Only when I correct myself: the fastest, with rules doing almost everything.") {
                Picker("", selection: $state.aiMode) {
                    ForEach(AIMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 230)
                .disabled(!state.aiCleanupEnabled)
            }
            Divide()
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(state.aiStatus.isReady ? Brand.green : Brand.amber)
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text(aiStatusText)
                        .font(Brand.text(13))
                        .foregroundStyle(Brand.cream)
                        .fixedSize(horizontal: false, vertical: true)
                    if !state.aiStatus.isReady {
                        Button("Open Apple Intelligence settings") {
                            Permissions.open(.appleIntelligence)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }

        Card {
            Text("How it stays fast and honest")
                .font(Brand.heading(14))
                .foregroundStyle(Brand.cream)
            bullet("Speed first. The model gets a short time limit. If it is too slow, your words are typed with the rule-based clean-up instead.")
            bullet("Say \"new line\", \"new paragraph\", \"bullet point\", \"open bracket\" and \"close bracket\", \"comma\", \"full stop\" or \"question mark\" and they are done for you.")
            bullet("It cleans. It never answers. Dictate a question and it stays a question.")
            bullet("Every answer is checked against what you said. If it added things, summarized, or wandered off, it is thrown away and your words are typed with the basic clean-up instead.")
            bullet("Your original words are always kept. Menu bar, then \"Copy what I actually said\".")
            bullet("Short bits like \"yes\" or \"sounds good\" skip the AI, so they appear instantly.")
        }

        Card {
            Text("Basic clean-up (always on)")
                .font(Brand.heading(14))
                .foregroundStyle(Brand.cream)
            Text("Removes um and uh, fixes \"the the\", applies clear self-corrections (\"no wait\", \"scratch that\") and spoken commands (\"new line\", \"open bracket\"), tidies punctuation and applies your word list. It is instant and runs on every dictation.")
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiStatusText: String {
        switch state.aiStatus {
        case .ready:
            return "The on-device model is ready."
        case .off(let reason):
            return reason
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Brand.amber)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Word list

    @ViewBuilder
    private var wordsPage: some View {
        title("Word list", "Names and words the speech model keeps getting wrong. Add the right spelling, and what it tends to hear instead.")

        Card {
            HStack(spacing: 10) {
                Text("Write it like this")
                    .frame(width: 190, alignment: .leading)
                Text("It sounds like (separate with commas)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Brand.textMedium(12))
            .foregroundStyle(Brand.faint)

            if state.vocabulary.entries.isEmpty {
                Text("No words yet.")
                    .font(Brand.text(13))
                    .foregroundStyle(Brand.muted)
            }
            ForEach(state.vocabulary.entries) { entry in
                WordRow(entry: entry, state: state)
            }

            Button("Add a word") {
                state.addWord()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: History

    @ViewBuilder
    private var historyPage: some View {
        title("History", "Your last 200 dictations, saved only on this Mac.")

        Card {
            SettingRow("Save history", detail: "Off: only the very last dictation is remembered, until you quit.") {
                switchControl($state.saveHistory)
            }
            if !state.entries.isEmpty {
                Divide()
                HStack {
                    Text("\(state.entries.count) saved")
                        .font(Brand.text(13))
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    Button("Clear history") {
                        state.clearHistory()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }

        if state.entries.isEmpty {
            Card {
                Text("Nothing here yet. Hold \(state.hotkey.shortTitle) and say something.")
                    .font(Brand.text(13))
                    .foregroundStyle(Brand.muted)
            }
        }
        ForEach(state.entries.prefix(100)) { entry in
            HistoryRow(entry: entry, state: state, controller: controller)
        }
    }

    // MARK: About

    @ViewBuilder
    private var aboutPage: some View {
        HStack(alignment: .center, spacing: 18) {
            OopsView(pose: .cool)
                .frame(width: 96, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("StupidTalk")
                    .font(Brand.display(30))
                    .foregroundStyle(Brand.cream)
                Text(AppInfo.tagline)
                    .font(Brand.textMedium(15))
                    .foregroundStyle(Brand.amber)
                Text("Version \(AppInfo.version)")
                    .font(Brand.text(12))
                    .foregroundStyle(Brand.faint)
            }
        }
        .padding(.bottom, 6)

        Card {
            Text("Mr. Oops has typed \(state.totalWords) words for you.")
                .font(Brand.textMedium(15))
                .foregroundStyle(Brand.cream)
            if let wait = state.lastWait {
                Text("Last one was typed \(String(format: "%.1f", wait)) seconds after you let go of the key.")
                    .font(Brand.text(13))
                    .foregroundStyle(Brand.amber)
            }
            Text("Free and open source. Your voice and your words never leave this Mac: speech to text and the AI clean-up both run on the models that come with macOS.")
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("stupidesigner.com") {
                    NSWorkspace.shared.open(AppInfo.website)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Source on GitHub") {
                    NSWorkspace.shared.open(AppInfo.repository)
                }
                .buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 10) {
                Button("Open log folder") {
                    try? FileManager.default.createDirectory(at: AppInfo.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppInfo.logDirectory)
                }
                .buttonStyle(QuietButtonStyle())
                Button("Copy speed report") {
                    controller.copySpeedReport()
                }
                .buttonStyle(QuietButtonStyle())
            }
        }

        Card {
            if let wordmark = Assets.image("wordmark") {
                Image(nsImage: wordmark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 30)
            }
            Text("Made by Stupidesigner. Stupid Name, Smart Design.")
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
            Text("The code is MIT licensed. The Stupidesigner name, the wordmark and Mr. Oops are brand assets and are not. Fonts: Archivo and DM Sans, SIL Open Font License.")
                .font(Brand.text(12))
                .foregroundStyle(Brand.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One editable line of the word list.
struct WordRow: View {
    let entry: VocabularyEntry
    let state: AppState
    @LocalState private var word: String
    @LocalState private var soundsLike: String

    init(entry: VocabularyEntry, state: AppState) {
        self.entry = entry
        self.state = state
        _word = LocalState(initialValue: entry.word)
        _soundsLike = LocalState(initialValue: entry.soundsLike.joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 10) {
            field("Stupidesigner", text: $word)
                .frame(width: 190)
            field("stupid designer, stupid e signer", text: $soundsLike)
            Button {
                state.removeWord(entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Brand.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this word")
        }
        .onChange(of: word) { _, newValue in
            state.updateWord(entry.id, word: newValue)
        }
        .onChange(of: soundsLike) { _, newValue in
            let parts = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            state.updateWord(entry.id, soundsLike: parts)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Brand.text(13))
            .foregroundStyle(Brand.cream)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Brand.line, lineWidth: 1))
    }
}

/// One past dictation, with both versions.
struct HistoryRow: View {
    let entry: HistoryEntry
    let state: AppState
    let controller: DictationController

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Text(HistoryRow.dateFormat.string(from: entry.date))
                if let app = entry.appName, !app.isEmpty {
                    Text("in \(app)")
                }
                if let wait = entry.wait {
                    Text("typed in \(String(format: "%.1f", wait)) s")
                }
                Spacer()
                Text(entry.usedAI ? "AI clean-up" : "Basic clean-up")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Brand.raised, in: Capsule())
            }
            .font(Brand.text(12))
            .foregroundStyle(Brand.faint)

            Text(entry.cleaned)
                .font(Brand.text(14))
                .foregroundStyle(Brand.cream)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if entry.raw != entry.cleaned {
                Text("You said: \(entry.raw)")
                    .font(Brand.text(12))
                    .foregroundStyle(Brand.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Copy") {
                    controller.copy(entry.cleaned)
                }
                .buttonStyle(QuietButtonStyle())
                Button("Copy what I said") {
                    controller.copy(entry.raw)
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Delete") {
                    state.removeEntry(entry.id)
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }
}
