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
            if self.anotherCopyStaysOpen() {
                Log.info("Another copy of StupidTalk is already running. This one quits.")
                NSApp.terminate(nil)
                return
            }
            // A menu bar app has no window most of the time. Without this, macOS is allowed to
            // quietly close such an app whenever it likes, and it would stop listening for the key.
            ProcessInfo.processInfo.disableAutomaticTermination("StupidTalk waits for its hold-to-talk key")
            ProcessInfo.processInfo.disableSuddenTermination()
            Log.info("StupidTalk \(AppInfo.version) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
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

            // Without Accessibility StupidTalk can only copy, not paste. macOS shows its own
            // "allow" dialog for this. After a new build the old permission no longer counts.
            if !state.accessibilityGranted {
                Log.info("Accessibility is not allowed yet. Asking macOS to show its dialog.")
                Permissions.promptForAccessibility()
            }
            // First run, or a permission went missing: show the setup checklist.
            if !state.setupFinished || state.microphonePermission != .granted || !state.accessibilityGranted {
                windows.showSetup()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If the log ever shows a start with no "quitting" before it, something closed the app from outside.
        Log.info("StupidTalk is quitting")
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

    /// True when another copy is running and is not on its way out.
    ///
    /// When macOS reopens the app (for example right after a permission change), the old copy
    /// can still be closing for a moment. Quitting at once would leave no copy running at all,
    /// so this waits a few seconds for the old one to go.
    private func anotherCopyStaysOpen() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != mine && !$0.isTerminated }
        }
        var waited = 0.0
        while !others().isEmpty, waited < 4 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        return !others().isEmpty
    }
}
