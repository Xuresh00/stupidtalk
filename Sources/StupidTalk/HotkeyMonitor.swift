import AppKit
import StupidTalkCore

/// Watches the keyboard for the hold-to-talk key, in every app.
///
/// macOS only delivers keyboard events from other apps once StupidTalk is allowed
/// under Privacy & Security > Accessibility.
@MainActor
final class HotkeyMonitor {
    var onAction: ((HoldToTalk.Action) -> Void)?

    var choice: HotkeyChoice {
        didSet { machine.reset() }
    }

    private var machine = HoldToTalk()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(choice: HotkeyChoice) {
        self.choice = choice
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        machine.reset()
    }

    private func handle(_ event: NSEvent) {
        let action: HoldToTalk.Action
        switch event.type {
        case .flagsChanged:
            let snapshot = ModifierSnapshot(rawFlags: event.modifierFlags.rawValue, choice: choice)
            action = machine.handle(.modifiers(snapshot, time: event.timestamp))
        case .keyDown:
            // Key code 53 is Escape.
            action = machine.handle(event.keyCode == 53 ? .escape : .otherKeyDown)
        default:
            action = .none
        }
        if action != .none {
            onAction?(action)
        }
    }
}
