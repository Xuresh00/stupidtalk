import Foundation

/// One finished dictation. Both versions are kept so the original words can always be recovered.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// What the speech recognizer heard, before any clean-up.
    public var raw: String
    /// What was typed at the cursor.
    public var cleaned: String
    /// True when the on-device AI cleaned this one. False means the rule-based clean-up was used.
    public var usedAI: Bool
    public var appName: String?
    /// From pressing the key to the text being typed.
    public var seconds: Double
    /// From letting go of the key to the text being typed. Missing in entries saved by 0.1.0.
    public var wait: Double?

    public init(id: UUID = UUID(), date: Date = Date(), raw: String, cleaned: String, usedAI: Bool, appName: String? = nil, seconds: Double = 0, wait: Double? = nil) {
        self.id = id
        self.date = date
        self.raw = raw
        self.cleaned = cleaned
        self.usedAI = usedAI
        self.appName = appName
        self.seconds = seconds
        self.wait = wait
    }
}

/// A small JSON file on disk. Newest entry first. Nothing leaves the Mac.
public final class HistoryStore {
    public let fileURL: URL
    public let limit: Int
    public private(set) var entries: [HistoryEntry] = []

    public init(fileURL: URL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = Swift.max(1, limit)
        load()
    }

    public func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = Array(decoded.prefix(limit))
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}

/// The personal word list on disk.
public enum VocabularyFile {
    public static func load(from url: URL) -> Vocabulary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Vocabulary.self, from: data)
    }

    public static func save(_ vocabulary: Vocabulary, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(vocabulary) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
