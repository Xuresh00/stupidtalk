import CryptoKit
import Foundation

/// Downloads speech models and keeps them in ~/Library/Application Support/StupidTalk/Models.
///
/// This is the only thing StupidTalk ever downloads. Each file is checked against its published
/// size and SHA-256 before it is used, and a file that does not match is thrown away.
/// All callbacks arrive on the main thread.
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    enum DownloadError: LocalizedError {
        case server(Int)
        case wrongSize
        case wrongChecksum

        var errorDescription: String? {
            switch self {
            case .server(let code): return "The download server answered \(code)."
            case .wrongSize: return "The downloaded file has the wrong size."
            case .wrongChecksum: return "The downloaded file did not pass its checksum."
            }
        }
    }

    static var directory: URL {
        AppInfo.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    static func fileURL(for choice: SpeechModelChoice) -> URL {
        directory.appendingPathComponent(choice.fileName)
    }

    /// True when the model file is here and has the right size.
    /// The full checksum is checked once, right after the download.
    static func isInstalled(_ choice: SpeechModelChoice) -> Bool {
        size(of: fileURL(for: choice)) == choice.sizeBytes
    }

    static func remove(_ choice: SpeechModelChoice) {
        try? FileManager.default.removeItem(at: fileURL(for: choice))
        try? FileManager.default.removeItem(at: partialURL(for: choice))
    }

    /// Half-finished downloads left over from a quit or a crash.
    static func removeLeftovers() {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == "download" {
            try? manager.removeItem(at: item)
        }
    }

    private(set) var downloading: SpeechModelChoice?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var lastReported: Double = -1

    func download(
        _ choice: SpeechModelChoice,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        cancel()
        downloading = choice
        onProgress = progress
        onFinish = completion
        lastReported = -1

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3 * 60 * 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session

        var request = URLRequest(url: choice.downloadURL)
        request.setValue("StupidTalk/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        downloading = nil
        onProgress = nil
        onFinish = nil
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard downloadTask === task, let choice = downloading else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : choice.sizeBytes
        let fraction = min(1, max(0, Double(totalBytesWritten) / Double(expected)))
        if fraction - lastReported >= 0.005 || fraction >= 1 {
            lastReported = fraction
            onProgress?(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask === task, let choice = downloading else { return }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(DownloadError.server(response.statusCode)))
            return
        }
        // The temporary file is gone once this method returns, so move it right away.
        let manager = FileManager.default
        let partial = Self.partialURL(for: choice)
        do {
            try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? manager.removeItem(at: partial)
            try manager.moveItem(at: location, to: partial)
        } catch {
            finish(.failure(error))
            return
        }
        // Checking 700 MB takes a second or two: not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.verifyAndInstall(partial, as: choice)
            DispatchQueue.main.async {
                self.finish(result)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled once the file is checked. Here only failures matter.
        guard task === self.task, let error else { return }
        finish(.failure(error))
    }

    // MARK: Helpers

    private func finish(_ result: Result<URL, Error>) {
        let completion = onFinish
        onFinish = nil
        onProgress = nil
        downloading = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion?(result)
    }

    private static func partialURL(for choice: SpeechModelChoice) -> URL {
        directory.appendingPathComponent(choice.fileName + ".download")
    }

    private static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func verifyAndInstall(_ partial: URL, as choice: SpeechModelChoice) -> Result<URL, Error> {
        let manager = FileManager.default
        guard size(of: partial) == choice.sizeBytes else {
            try? manager.removeItem(at: partial)
            return .failure(DownloadError.wrongSize)
        }
        guard sha256(of: partial) == choice.sha256 else {
            try? manager.removeItem(at: partial)
            return .failure(DownloadError.wrongChecksum)
        }
        var installed = fileURL(for: choice)
        try? manager.removeItem(at: installed)
        do {
            try manager.moveItem(at: partial, to: installed)
        } catch {
            return .failure(error)
        }
        // It can always be downloaded again, so keep it out of Time Machine backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? installed.setResourceValues(values)
        return .success(installed)
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 8 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
