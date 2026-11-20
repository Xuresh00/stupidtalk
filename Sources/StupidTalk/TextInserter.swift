import AppKit
import StupidTalkCore

/// How the text gets into the app you are using.
enum InsertMethod: String, CaseIterable {
    /// Types the words like a keyboard would. Your clipboard is never touched. The default.
    case type
    /// Puts the words on the clipboard, presses Command-V, then puts your clipboard back.
    case paste

    var title: String {
        switch self {
        case .type: return "Type it (your clipboard stays as it is)"
        case .paste: return "Paste it"
        }
    }
}

enum InsertResult {
    case inserted
    /// macOS has not allowed StupidTalk to press keys yet (Accessibility).
    case needsAccessibility
}

/// Puts text where your cursor is.
///
/// By default it types: the words go in as key presses, a few characters at a time, so
/// whatever you copied before stays on your clipboard. Line breaks are typed as Shift-Return,
/// which makes a new line in chat apps instead of sending the message.
final class TextInserter {
    /// Marks the key presses StupidTalk makes, so its own key watcher can ignore them.
    static let eventMarker: Int64 = 0x5354_414C_4B

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let typingQueue = DispatchQueue(label: "com.stupidesigner.stupidtalk.typing", qos: .userInteractive)

    @MainActor
    func insert(_ text: String, method: InsertMethod) async -> InsertResult {
        guard Permissions.accessibilityGranted else { return .needsAccessibility }
        switch method {
        case .type:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                typingQueue.async {
                    Self.type(text)
                    continuation.resume()
                }
            }
        case .paste:
            await paste(text)
        }
        return .inserted
    }

    /// Puts the text on the clipboard and leaves it there. Only when you ask for it.
    @MainActor
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Typing

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in TypingChunks.split(text) {
            switch chunk {
            case .text(let piece):
                let units = Array(piece.utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
                units.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                // No modifiers, even if one is still held: Option plus a letter would type a symbol.
                down.flags = []
                up.flags = []
                post(down)
                post(up)
            case .lineBreak:
                // Key code 36 is Return.
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { continue }
                down.flags = .maskShift
                up.flags = .maskShift
                post(down)
                post(up)
            }
            // A short pause between key presses, so busy apps keep up and drop nothing.
            usleep(3_000)
        }
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Pasting

    @MainActor
    private func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        // Marked as temporary, so clipboard managers skip it.
        pasteboard.declareTypes([.string, Self.transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        let ours = pasteboard.changeCount

        Self.pressCommandV()

        // Give the app a moment to read it, then put your clipboard back exactly as it was.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard pasteboard.changeCount == ours else { return } // You copied something new meanwhile.
        pasteboard.clearContents()
        if !saved.isEmpty {
            let items = saved.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in types {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Key code 9 is V on a US-style layout.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        post(down)
        post(up)
    }

    /// Every item and every type on the clipboard, so it can be put back as it was.
    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type] = data
                }
            }
            return types
        }
    }
}
