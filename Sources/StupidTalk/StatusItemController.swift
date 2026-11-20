import AppKit
import Combine
import StupidTalkCore

/// Mr. Oops in the menu bar, and the menu behind him.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let state: AppState
    private let controller: DictationController
    private let windows: WindowCoordinator
    private let baseImage: NSImage?
    private var subscriptions = Set<AnyCancellable>()

    init(state: AppState, controller: DictationController, windows: WindowCoordinator) {
        self.state = state
        self.controller = controller
        self.windows = windows
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.baseImage = Assets.image("menubar")
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "StupidTalk"
        updateIcon(for: state.phase)

        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    self?.updateIcon(for: phase)
                }
            }
            .store(in: &subscriptions)
    }

    // MARK: Icon

    private func updateIcon(for phase: DictationPhase) {
        let badge: NSColor?
        switch phase {
        case .idle: badge = nil
        case .listening: badge = Brand.redNS
        case .transcribing, .cleaning: badge = Brand.amberNS
        }
        statusItem.button?.image = icon(badge: badge)
    }

    /// Mr. Oops at menu bar size, with a small dot while he is listening or working.
    private func icon(badge: NSColor?) -> NSImage {
        let side: CGFloat = 20
        let base = baseImage
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if let base {
                let scale = min(rect.width / base.size.width, rect.height / base.size.height)
                let width = base.size.width * scale
                let height = base.size.height * scale
                let target = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
                base.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            } else if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "StupidTalk") {
                symbol.draw(in: rect.insetBy(dx: 3, dy: 2))
            }
            if let badge {
                let dot = NSRect(x: rect.maxX - 7, y: rect.minY, width: 7, height: 7)
                badge.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let wait = state.lastWait {
            let speed = NSMenuItem(title: "Last one: typed \(String(format: "%.1f", wait)) s after you let go", action: nil, keyEquivalent: "")
            speed.isEnabled = false
            menu.addItem(speed)
        }
        menu.addItem(.separator())

        let cleanup = item("AI polish", #selector(toggleCleanup))
        cleanup.state = state.aiCleanupEnabled ? .on : .off
        menu.addItem(cleanup)
        if state.aiCleanupEnabled, case .off(let reason) = state.aiStatus {
            let note = NSMenuItem(title: shortened(reason), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let hasLast = state.lastEntry != nil
        let paste = item("Type last result again", #selector(pasteLast))
        paste.isEnabled = hasLast
        menu.addItem(paste)
        let copy = item("Copy last result", #selector(copyLast))
        copy.isEnabled = hasLast
        menu.addItem(copy)
        let copyRaw = item("Copy what I actually said", #selector(copyLastRaw))
        copyRaw.isEnabled = hasLast
        menu.addItem(copyRaw)
        menu.addItem(.separator())

        menu.addItem(item("History", #selector(openHistory)))
        menu.addItem(item("Word list", #selector(openWords)))
        menu.addItem(item("Settings", #selector(openSettings), key: ","))
        menu.addItem(item("Check setup", #selector(openSetup)))
        menu.addItem(item("Copy speed report", #selector(copySpeedReport)))
        menu.addItem(.separator())
        menu.addItem(item("About StupidTalk", #selector(openAbout)))
        menu.addItem(item("Quit StupidTalk", #selector(quit), key: "q"))
    }

    private var statusLine: String {
        if state.microphonePermission != .granted || !state.accessibilityGranted {
            return "Setup needed. Open Check setup."
        }
        switch state.speechStatus {
        case .ready: break
        case .downloading(let fraction): return "Downloading the speech model (\(Int(fraction * 100))%)"
        case .loading: return "Loading the speech model"
        default: return "Speech model not ready. Open Check setup."
        }
        switch state.phase {
        case .idle: return "Hold \(state.hotkey.shortTitle) and talk"
        case .listening: return "Listening"
        case .transcribing: return "Writing it down"
        case .cleaning: return "Cleaning up"
        }
    }

    private func shortened(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "..." : text
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: Actions

    @objc private func toggleCleanup() {
        state.aiCleanupEnabled.toggle()
    }

    @objc private func pasteLast() {
        controller.typeLastResult()
    }

    @objc private func copyLast() {
        controller.copyLastResult(raw: false)
    }

    @objc private func copyLastRaw() {
        controller.copyLastResult(raw: true)
    }

    @objc private func openHistory() {
        windows.showSettings(tab: .history)
    }

    @objc private func openWords() {
        windows.showSettings(tab: .words)
    }

    @objc private func openSettings() {
        windows.showSettings(tab: .general)
    }

    @objc private func openSetup() {
        windows.showSetup()
    }

    @objc private func copySpeedReport() {
        controller.copySpeedReport()
    }

    @objc private func openAbout() {
        windows.showSettings(tab: .about)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
