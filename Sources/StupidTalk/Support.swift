import AppKit
import Foundation

enum AppInfo {
    static let name = "StupidTalk"
    static let tagline = "Stupid talk. Smart text."
    static let website = URL(string: "https://stupidesigner.com")!
    static let repository = URL(string: "https://github.com/Xuresh00/stupidtalk")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// ~/Library/Application Support/StupidTalk. The word list and the history live here.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// ~/Library/Logs/StupidTalk
    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/\(name)", isDirectory: true)
    }
}

/// A plain text log for troubleshooting. It records what happened and how long it took,
/// never what you said.
///
/// Lines are written straight away, and the last ones are also kept in memory, so a speed
/// report can still be copied when the file cannot be written.
enum Log {
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024
    private static let keep = 80
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static var lines: [String] = []
    private static var writeProblem: String?

    static var fileURL: URL { AppInfo.logDirectory.appendingPathComponent("stupidtalk.log") }

    /// The latest lines, newest last.
    static var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// Why the log file could not be written, when it could not.
    static var problem: String? {
        lock.lock()
        defer { lock.unlock() }
        return writeProblem
    }

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        do {
            try append(line + "\n")
            writeProblem = nil
        } catch {
            writeProblem = error.localizedDescription
        }
    }

    private static func append(_ text: String) throws {
        let manager = FileManager.default
        let url = fileURL
        try manager.createDirectory(at: AppInfo.logDirectory, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = AppInfo.logDirectory.appendingPathComponent("stupidtalk.old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        let data = Data(text.utf8)
        if manager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}

/// Runs an async job, but gives up waiting after a while. The job itself is cancelled
/// and left to wind down on its own, so a stuck model can never freeze a dictation.
enum Race {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "That took too long." }
    }

    private final class Gate {
        private let lock = NSLock()
        private var used = false

        func pass() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    static func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let gate = Gate()
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.pass() { continuation.resume(returning: value) }
                } catch {
                    if gate.pass() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.pass() {
                    work.cancel()
                    continuation.resume(throwing: TimedOut())
                }
            }
        }
    }
}

/// Tiny optional sound cues, using sounds that ship with macOS.
@MainActor
enum Sounds {
    static func start() { NSSound(named: NSSound.Name("Tink"))?.play() }
    static func done() { NSSound(named: NSSound.Name("Pop"))?.play() }
    static func problem() { NSSound(named: NSSound.Name("Basso"))?.play() }
}
