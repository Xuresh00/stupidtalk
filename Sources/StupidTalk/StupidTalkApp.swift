import AppKit
import SwiftUI

// StupidTalk lives in the menu bar. It has no Dock icon and no main window:
// Info.plist sets LSUIElement, and everything is set up by AppDelegate.
@main
struct StupidTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // SwiftUI wants at least one scene. The real windows are plain AppKit windows
        // managed by WindowCoordinator, so the standard Settings command is pointed at those.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    delegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var windows: WindowCoordinator?
    private var controller: DictationController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if self.anotherCopyIsRunning() {
                NSApp.terminate(nil)
                return
            }
            Log.info("StupidTalk \(AppInfo.version) started")
            Assets.registerFonts()
            NSApp.setActivationPolicy(.accessory)

            let state = AppState()
            let windows = WindowCoordinator(state: state)
            let controller = DictationController(state: state, windows: windows)
            windows.controller = controller
            let statusItem = StatusItemController(state: state, controller: controller, windows: windows)

            self.state = state
            self.windows = windows
            self.controller = controller
            self.statusItem = statusItem

            controller.start()

            // First run, or a permission went missing: show the setup checklist.
            if !state.setupFinished || state.microphonePermission != .granted || !state.accessibilityGranted {
                windows.showSetup()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        MainActor.assumeIsolated {
            windows?.showSettings(tab: .general)
        }
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0.processIdentifier != mine }
    }
}
