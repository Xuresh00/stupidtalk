import AppKit
import ApplicationServices
import AVFoundation

enum MicrophonePermission: Equatable {
    case granted
    case denied
    case notAsked
}

/// The System Settings pages StupidTalk can send you to.
enum SettingsPane: String {
    case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case appleIntelligence = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
    case keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
}

/// StupidTalk needs two permissions:
/// - Microphone, to hear you.
/// - Accessibility, to notice the hold-to-talk key in any app and to type the words at your cursor.
enum Permissions {
    static var microphone: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the macOS prompt that leads to the Accessibility list.
    static func promptForAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func open(_ pane: SettingsPane) {
        if let url = URL(string: pane.rawValue) {
            NSWorkspace.shared.open(url)
        }
    }
}
