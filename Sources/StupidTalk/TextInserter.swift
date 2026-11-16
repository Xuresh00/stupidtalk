import AppKit

enum InsertResult {
    /// The text was pasted at the cursor.
    case pasted
    /// Accessibility permission is missing, so the text was only put on the clipboard.
    case copiedOnly
}

/// Types text at the cursor of whatever app is in front.
///
/// It does this the way almost every dictation app does: put the text on the clipboard,
/// press Command-V for you, then put your old clipboard back.
final class TextInserter {
    /// Clipboard managers skip entries marked with this type (nspasteboard.org convention).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Bigger clipboards than this are not saved and restored.
    private static let snapshotLimit = 30 * 1024 * 1024

    func insert(_ text: String, keepOnClipboard: Bool) -> InsertResult {
        let pasteboard = NSPasteboard.general
        guard Permissions.accessibilityGranted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        let saved = keepOnClipboard ? nil : snapshot(of: pasteboard)
        pasteboard.clearContents()
        if keepOnClipboard {
            pasteboard.setString(text, forType: .string)
        } else {
            pasteboard.declareTypes([.string, Self.transientType], owner: nil)
            pasteboard.setString(text, forType: .string)
            pasteboard.setData(Data(), forType: Self.transientType)
        }
        let changeCount = pasteboard.changeCount

        pressCommandV()

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // If you copied something else in the meantime, leave it alone.
                guard pasteboard.changeCount == changeCount else { return }
                TextInserter.restore(saved, to: pasteboard)
            }
        }
        return .pasted
    }

    /// Puts text on the clipboard and leaves it there.
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key 9 is the V key on a QWERTY layout.
        let keyV: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]]? {
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > Self.snapshotLimit { return nil }
                contents[type] = data
            }
            items.append(contents)
        }
        return items
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects: [NSPasteboardItem] = items.compactMap { contents in
            guard !contents.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        if !objects.isEmpty {
            pasteboard.writeObjects(objects)
        }
    }
}
