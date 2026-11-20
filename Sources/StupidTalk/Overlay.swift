import AppKit
import SwiftUI

/// What the little pill at the bottom of the screen is showing.
enum OverlayState: Equatable {
    case hidden
    case listening
    /// Turning speech into text.
    case thinking
    /// The AI clean-up is running. The text is a short progress label.
    case cleaning(String)
    case done
    /// The words are in. A Copy button shows for a moment, for when you want them on the clipboard too.
    /// `note` replaces "Done" when there is something to say.
    case typed(text: String, note: String?)
    case copied
    case message(String, OopsPose)

    /// Only the Copy moment takes clicks. The rest of the time clicks go straight through.
    var takesClicks: Bool {
        if case .typed = self { return true }
        return false
    }
}

/// How many level bars the pill shows.
private let levelBarCount = 18

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: levelBarCount)
    /// True while the pointer is on the pill, so the Copy button doesn't vanish under it.
    @Published var hovering = false
    var onCopy: ((String) -> Void)?

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(CGFloat(level))
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: levelBarCount)
    }
}

/// A small floating pill with Mr. Oops. It never takes keyboard focus, so the app you
/// are dictating into stays in front.
@MainActor
final class OverlayController {
    let model: OverlayModel
    private var panel: NSPanel?
    private var generation = 0
    private let size = NSSize(width: 420, height: 96)

    init() {
        model = OverlayModel()
    }

    /// Called with the text when you click Copy.
    var copyHandler: ((String) -> Void)?

    func show(_ state: OverlayState) {
        generation += 1
        if state == .listening { model.resetLevels() }
        if !state.takesClicks { model.hovering = false }
        model.state = state
        makePanelIfNeeded()
        panel?.ignoresMouseEvents = !state.takesClicks
        position()
        panel?.orderFrontRegardless()
    }

    /// Shows "Done" with a Copy button for `seconds`, longer while the pointer is on it.
    func offerCopy(_ text: String, note: String? = nil, seconds: Double = 2) {
        show(.typed(text: text, note: note))
        let shown = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Don't pull the button away from under the pointer.
            while let self, self.generation == shown, self.model.hovering {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    private func copyTapped(_ text: String) {
        copyHandler?(text)
        flash(.copied, seconds: 0.9)
    }

    /// Shows a state for a moment, then hides the pill.
    func flash(_ state: OverlayState, seconds: Double = 1.0) {
        show(state)
        let shown = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        model.state = .hidden
        model.hovering = false
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        model.onCopy = { [weak self] text in self?.copyTapped(text) }
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel
    }

    /// Bottom centre of the screen the pointer is on, just above the Dock.
    private func position() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height),
            display: true
        )
    }
}

/// A panel that never takes keyboard focus. Clicking it leaves your app in front.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the very first click, so one click on Copy is enough even though the pill is never focused.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            if model.state != .hidden {
                HStack(spacing: 12) {
                    OopsView(pose: pose)
                        .frame(width: 46, height: 52)
                    content
                }
                .padding(.leading, 14)
                .padding(.trailing, 22)
                .padding(.vertical, 8)
                .background(Brand.surface, in: Capsule())
                .overlay(Capsule().stroke(Brand.line, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
                .contentShape(Capsule())
                .onHover { model.hovering = $0 }
                .transition(.opacity)
            }
        }
        .frame(width: 420, height: 96)
        .animation(.easeOut(duration: 0.15), value: model.state)
    }

    private var pose: OopsPose {
        switch model.state {
        case .hidden: return .rock
        case .listening: return .point
        case .thinking: return .laptop
        case .cleaning: return .pencil
        case .done, .typed, .copied: return .done
        case .message(_, let pose): return pose
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .listening:
            LevelBars(levels: model.levels)
        case .thinking:
            label("Got it")
        case .cleaning(let progress):
            label(progress)
        case .done:
            label("Done")
        case .typed(let text, let note):
            HStack(spacing: 12) {
                if let note {
                    label(note, maxWidth: 190)
                } else {
                    Text("Done")
                        .font(Brand.textMedium(14))
                        .foregroundStyle(Brand.cream)
                        .fixedSize()
                }
                Button {
                    model.onCopy?(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillCopyButtonStyle())
                .help("Put this text on the clipboard too")
            }
        case .copied:
            label("Copied")
        case .message(let text, _):
            label(text)
        }
    }

    private func label(_ text: String, maxWidth: CGFloat = 250) -> some View {
        Text(text)
            .font(Brand.textMedium(14))
            .foregroundStyle(Brand.cream)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// The small amber Copy button in the pill.
struct PillCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.textBold(13))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Brand.amberBright : Brand.amber, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The moving bars that show StupidTalk can hear you.
struct LevelBars: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Brand.amber)
                    .frame(width: 4, height: max(5, 34 * levels[index]))
            }
        }
        .frame(height: 36)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
