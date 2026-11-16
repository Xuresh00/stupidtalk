import AppKit
import SwiftUI

/// Opens the two windows StupidTalk has: Settings and the setup checklist.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let state: AppState
    weak var controller: DictationController?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func showSettings(tab: SettingsTab) {
        guard let controller else { return }
        state.settingsTab = tab
        if settingsWindow == nil {
            let view = SettingsView(state: state, controller: controller)
            settingsWindow = makeWindow(title: "StupidTalk", size: NSSize(width: 780, height: 580), content: AnyView(view))
        }
        present(settingsWindow)
    }

    func showSetup() {
        guard let controller else { return }
        if setupWindow == nil {
            let view = SetupView(state: state, controller: controller) { [weak self] in
                self?.closeSetup()
            }
            setupWindow = makeWindow(title: "Set up StupidTalk", size: NSSize(width: 620, height: 720), content: AnyView(view))
        }
        present(setupWindow)
    }

    private func closeSetup() {
        state.setupFinished = true
        setupWindow?.close()
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, size: NSSize, content: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Brand.inkNS
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        window.center()
        window.delegate = self
        return window
    }
}
