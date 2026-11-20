import StupidTalkCore
import SwiftUI

/// The first-run checklist. It also opens from the menu ("Check setup") any time something stops working.
struct SetupView: View {
    @ObservedObject var state: AppState
    let controller: DictationController
    let onDone: () -> Void
    @LocalState private var sample = ""

    init(state: AppState, controller: DictationController, onDone: @escaping () -> Void) {
        self.state = state
        self.controller = controller
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                microphoneStep
                accessibilityStep
                speechStep
                tryIt
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 26)
        }
        .frame(minWidth: 620, minHeight: 720)
        .background(Brand.ink)
        .preferredColorScheme(.dark)
        .tint(Brand.amber)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            OopsView(pose: state.everythingReady ? .done : .rock)
                .frame(width: 84, height: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.everythingReady ? "You're set" : "Let's get you talking")
                    .font(Brand.display(24))
                    .foregroundStyle(Brand.cream)
                Text("Hold \(state.hotkey.shortTitle), talk, let go. Mr. Oops types it where your cursor is. Three quick checks first.")
                    .font(Brand.text(13))
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Steps

    private var microphoneStep: some View {
        Step(
            number: 1,
            title: "Microphone",
            detail: "So StupidTalk can hear you. It only listens while you hold the key.",
            status: state.microphonePermission == .granted ? .ready : .needsYou
        ) {
            if state.microphonePermission != .granted {
                Button(state.microphonePermission == .notAsked ? "Allow microphone" : "Open Microphone settings") {
                    controller.requestMicrophone()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var accessibilityStep: some View {
        Step(
            number: 2,
            title: "Accessibility",
            detail: "Lets StupidTalk notice the hold-to-talk key in any app and type the words at your cursor. Switch StupidTalk on in the list, then come back. This turns green by itself.",
            status: state.accessibilityGranted ? .ready : .needsYou
        ) {
            if !state.accessibilityGranted {
                Button("Open Accessibility settings") {
                    controller.requestAccessibility()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var speechStep: some View {
        Step(
            number: 3,
            title: "Speech model",
            detail: speechDetail,
            status: speechStepStatus
        ) {
            switch state.speechStatus {
            case .needsDownload:
                Button("Download \(state.speechModel.title) (\(state.speechModel.sizeText))") {
                    controller.downloadSpeechModel()
                }
                .buttonStyle(PrimaryButtonStyle())
            case .downloading(let fraction):
                HStack(spacing: 12) {
                    ProgressView(value: min(1, max(0, fraction)))
                        .frame(width: 240)
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .font(Brand.textMedium(12))
                        .foregroundStyle(Brand.muted)
                        .monospacedDigit()
                }
            case .unavailable:
                Button("Download again") {
                    controller.redownloadSpeechModel()
                }
                .buttonStyle(QuietButtonStyle())
            case .unknown, .loading:
                ProgressView()
                    .controlSize(.small)
            case .ready:
                EmptyView()
            }
        }
    }

    private var speechDetail: String {
        let model = state.speechModel
        switch state.speechStatus {
        case .ready:
            return "\(model.title) is ready. It runs on this Mac's GPU, and your voice never leaves the Mac."
        case .needsDownload:
            return "A one-time download of \(model.title), the speech-to-text model (\(model.sizeText)). After that it works offline."
        case .downloading:
            return "Downloading \(model.title). You can keep using your Mac meanwhile."
        case .loading:
            return "Loading \(model.title). A few seconds."
        case .unavailable(let reason):
            return reason
        case .unknown:
            return "Checking the speech model."
        }
    }

    private var speechStepStatus: StepStatus {
        switch state.speechStatus {
        case .ready: return .ready
        case .downloading, .unknown, .loading: return .working
        case .needsDownload, .unavailable: return .needsYou
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        Card {
            Text("Try it")
                .font(Brand.heading(15))
                .foregroundStyle(Brand.cream)
            Text("Click in the box, hold \(state.hotkey.shortTitle), say something like \"um, send it on Monday, no wait, Tuesday\", then let go.")
                .font(Brand.text(13))
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $sample)
                .font(Brand.text(14))
                .foregroundStyle(Brand.cream)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 92)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line, lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack {
            Text("Find all of this later under Mr. Oops in the menu bar.")
                .font(Brand.text(12))
                .foregroundStyle(Brand.faint)
            Spacer()
            Button(state.everythingReady ? "Done" : "Finish later") {
                onDone()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

enum StepStatus: Equatable {
    case ready
    case needsYou
    case working
}

/// One numbered line of the checklist.
struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let status: StepStatus
    let action: Action

    init(number: Int, title: String, detail: String, status: StepStatus, @ViewBuilder action: () -> Action) {
        self.number = number
        self.title = title
        self.detail = detail
        self.status = status
        self.action = action()
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Text("\(number)")
                    .font(Brand.heading(14))
                    .foregroundStyle(status == .ready ? Brand.ink : Brand.cream)
                    .frame(width: 30, height: 30)
                    .background(status == .ready ? Brand.green : Brand.raised, in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(Brand.textBold(15))
                            .foregroundStyle(Brand.cream)
                        Spacer()
                        Text(chipText)
                            .font(Brand.textMedium(11))
                            .foregroundStyle(chipColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(chipColor.opacity(0.14), in: Capsule())
                    }
                    Text(detail)
                        .font(Brand.text(13))
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    action
                }
            }
        }
    }

    private var chipText: String {
        switch status {
        case .ready: return "Ready"
        case .needsYou: return "Needs you"
        case .working: return "Working"
        }
    }

    private var chipColor: Color {
        switch status {
        case .ready: return Brand.green
        case .needsYou: return Brand.amber
        case .working: return Brand.muted
        }
    }
}
