import Foundation

/// One step when StupidTalk types text with synthetic key presses.
public enum TypingChunk: Equatable, Sendable {
    /// A few characters sent in one key press.
    case text(String)
    /// A new line. Typed as Shift-Return, because a plain Return sends the message in chat apps.
    case lineBreak
}

/// Splits text into key presses, so it can be typed without touching the clipboard.
///
/// macOS carries at most 20 UTF-16 units in one key event, so longer text goes out in pieces.
/// A character (an emoji, or a letter with an accent) is never split across two pieces.
public enum TypingChunks {
    /// The most UTF-16 units one key press carries. macOS allows 20, a little less is safer.
    public static let maxUnitsPerEvent = 16

    public static func split(_ text: String, maxUnits: Int = maxUnitsPerEvent) -> [TypingChunk] {
        let limit = max(1, maxUnits)
        var chunks: [TypingChunk] = []
        var current = ""
        var currentUnits = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(.text(current))
            current = ""
            currentUnits = 0
        }

        for character in text {
            // "\r\n" is one Character, so a Windows line ending is one line break, not two.
            if character.isNewline {
                flush()
                chunks.append(.lineBreak)
                continue
            }
            let units = character.utf16.count
            if currentUnits > 0, currentUnits + units > limit {
                flush()
            }
            current.append(character)
            currentUnits += units
        }
        flush()
        return chunks
    }
}
