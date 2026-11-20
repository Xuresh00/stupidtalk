import Foundation

/// The speech-to-text models StupidTalk can use. Both run on this Mac through transcribe.cpp,
/// the open-source engine the Handy app runs on, with the GPU doing the work.
/// The files are the GGUF builds Handy publishes on Hugging Face.
enum SpeechModelChoice: String, CaseIterable, Identifiable {
    case parakeet
    case whisperTurbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisperTurbo: return "Whisper Turbo"
        }
    }

    var menuTitle: String {
        switch self {
        case .parakeet: return "Parakeet: English, recommended (\(sizeText))"
        case .whisperTurbo: return "Whisper Turbo: also knows Hindi (\(sizeText))"
        }
    }

    var detail: String {
        switch self {
        case .parakeet:
            return "NVIDIA's English model. In transcribe.cpp's tests it makes the fewest mistakes of the two and is about eight times faster."
        case .whisperTurbo:
            return "OpenAI's Whisper. A bit slower. Try it if Parakeet keeps mishearing your accent. It also understands Hindi, for later."
        }
    }

    var fileName: String {
        switch self {
        case .parakeet: return "parakeet-unified-en-0.6b-Q8_0.gguf"
        case .whisperTurbo: return "whisper-large-v3-turbo-Q8_0.gguf"
        }
    }

    var downloadURL: URL {
        let repo: String
        switch self {
        case .parakeet: repo = "handy-computer/parakeet-unified-en-0.6b-gguf"
        case .whisperTurbo: repo = "handy-computer/whisper-large-v3-turbo-gguf"
        }
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")!
    }

    /// Exact size of the published file, in bytes.
    var sizeBytes: Int64 {
        switch self {
        case .parakeet: return 731_357_568
        case .whisperTurbo: return 886_381_728
        }
    }

    /// SHA-256 of the published file. A download that does not match is thrown away.
    var sha256: String {
        switch self {
        case .parakeet: return "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
        case .whisperTurbo: return "257aa7ec9121c22c167d5e2c49e3e76b4ba0e6e27ebc13074eba0a80f8190220"
        }
    }

    var license: String {
        switch self {
        case .parakeet: return "NVIDIA Open Model License"
        case .whisperTurbo: return "MIT"
        }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Where the speech model is at.
enum SpeechModelStatus: Equatable {
    case unknown
    /// The model file is not on this Mac yet.
    case needsDownload
    /// Downloading, 0...1.
    case downloading(Double)
    /// The file is here and being loaded onto the GPU.
    case loading
    case ready
    /// Something went wrong. The text says what, in plain words.
    case unavailable(String)
}
