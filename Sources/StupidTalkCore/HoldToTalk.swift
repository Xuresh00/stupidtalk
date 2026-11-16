import Foundation

/// The key you hold while you talk.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case rightOption
    case rightCommand
    case fn

    public var title: String {
        switch self {
        case .rightOption: return "Right Option (\u{2325})"
        case .rightCommand: return "Right Command (\u{2318})"
        case .fn: return "Fn / Globe"
        }
    }

    public var shortTitle: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .fn: return "Fn"
        }
    }

    public var symbol: String {
        switch self {
        case .rightOption: return "\u{2325}"
        case .rightCommand: return "\u{2318}"
        case .fn: return "fn"
        }
    }

    /// The bit this key sets in the raw modifier flags of a keyboard event.
    var ownMask: UInt {
        switch self {
        case .rightOption: return ModifierBits.rightOption
        case .rightCommand: return ModifierBits.rightCommand
        case .fn: return ModifierBits.function
        }
    }

    /// Bits that mean "some other modifier key is down too".
    var otherMask: UInt {
        switch self {
        case .rightOption:
            return ModifierBits.shift | ModifierBits.control | ModifierBits.command | ModifierBits.function | ModifierBits.leftOption
        case .rightCommand:
            return ModifierBits.shift | ModifierBits.control | ModifierBits.option | ModifierBits.function | ModifierBits.leftCommand
        case .fn:
            return ModifierBits.shift | ModifierBits.control | ModifierBits.option | ModifierBits.command
        }
    }
}

/// Raw modifier flag bits as macOS reports them (`NSEvent.modifierFlags.rawValue`).
/// The low bits tell the left key from the right key.
public enum ModifierBits {
    public static let shift: UInt = 0x20000
    public static let control: UInt = 0x40000
    public static let option: UInt = 0x80000
    public static let command: UInt = 0x100000
    public static let function: UInt = 0x800000
    public static let leftCommand: UInt = 0x08
    public static let rightCommand: UInt = 0x10
    public static let leftOption: UInt = 0x20
    public static let rightOption: UInt = 0x40
}

public struct ModifierSnapshot: Equatable, Sendable {
    public var hotkeyDown: Bool
    public var othersDown: Bool

    public init(rawFlags: UInt, choice: HotkeyChoice) {
        hotkeyDown = rawFlags & choice.ownMask != 0
        othersDown = rawFlags & choice.otherMask != 0
    }
}

/// Decides when a dictation starts, ends or is thrown away, from plain key events.
///
/// Rules:
/// - Hotkey goes down on its own: start recording right away, so no word is lost.
/// - Hotkey comes up: finish. A very short tap is treated as an accident and cancelled.
/// - Any other key or modifier while holding: you are typing a shortcut, so cancel.
/// - Escape while holding: cancel.
public struct HoldToTalk: Sendable {
    public enum Event: Equatable, Sendable {
        /// The modifier keys changed. `time` is in seconds, from any steady clock.
        case modifiers(ModifierSnapshot, time: TimeInterval)
        case otherKeyDown
        case escape
    }

    public enum Action: Equatable, Sendable {
        case none
        case start
        case finish
        case cancel
    }

    public var minimumHold: TimeInterval

    private var hotkeyIsDown = false
    private var recording = false
    private var downAt: TimeInterval = 0

    public init(minimumHold: TimeInterval = 0.25) {
        self.minimumHold = minimumHold
    }

    public var isRecording: Bool { recording }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .modifiers(let snapshot, let time):
            if snapshot.hotkeyDown && !hotkeyIsDown {
                hotkeyIsDown = true
                // Pressed together with another modifier: a shortcut, not a dictation.
                guard !snapshot.othersDown else { return .none }
                recording = true
                downAt = time
                return .start
            }
            if !snapshot.hotkeyDown && hotkeyIsDown {
                hotkeyIsDown = false
                guard recording else { return .none }
                recording = false
                return time - downAt < minimumHold ? .cancel : .finish
            }
            if snapshot.hotkeyDown && recording && snapshot.othersDown {
                recording = false
                return .cancel
            }
            return .none

        case .otherKeyDown, .escape:
            guard recording else { return .none }
            recording = false
            return .cancel
        }
    }

    /// Forget everything, for example after the hotkey setting changes.
    public mutating func reset() {
        hotkeyIsDown = false
        recording = false
    }
}
