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

    /// Asks macOS directly whether the hold-to-talk key is down right now.
    /// A safety net for the rare case where the "key released" event never arrives.
    func isKeyDown() -> Bool {
        // Either source saying "down" counts, so a dictation is never cut short by mistake.
        NSEvent.modifierFlags.contains(choice.modifier)
            || CGEventSource.keyState(.combinedSessionState, key: choice.keyCode)
    }

    /// Forget a hold whose release was noticed by `isKeyDown` and not by an event.
    func forgetHold() {
        machine.reset()
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

extension HotkeyChoice {
    /// The modifier this key belongs to, left or right.
    var modifier: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .fn: return .function
        }
    }

    /// The key's hardware code (Carbon virtual key codes).
    var keyCode: CGKeyCode {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }
}
