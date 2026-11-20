import Foundation

/// Finds the part of a recording that has your voice in it, by loudness alone.
///
/// The quiet bit before you start talking and after you stop is cut off, with some padding left
/// on both sides so no soft first or last word is lost. A recording that is silence all the way
/// through gives nil, so the speech model is never asked to guess words out of nothing.
public enum AudioTrim {
    /// Below this, even at its loudest moment, a recording is treated as silence.
    /// Real speech, even quiet speech into a laptop microphone, is far above it.
    public static let silencePeak: Float = 0.0015

    /// Audio kept before the first and after the last loud moment, in seconds.
    public static let padding: Double = 0.35

    /// The range of `samples` worth transcribing, or nil when there is nothing to hear.
    /// `samples` are mono, between -1 and 1.
    public static func speechRange(_ samples: [Float], sampleRate: Int = 16_000) -> Range<Int>? {
        let frameLength = max(1, sampleRate / 50) // 20 ms
        guard samples.count >= frameLength else { return nil }

        var loudness: [Float] = []
        loudness.reserveCapacity(samples.count / frameLength + 1)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameLength)
            var sum: Float = 0
            for index in start..<end {
                sum += samples[index] * samples[index]
            }
            loudness.append((sum / Float(end - start)).squareRoot())
            start = end
        }

        guard let peak = loudness.max(), peak >= silencePeak else { return nil }
        // Relative to the loudest moment, so it works for quiet and loud microphones alike.
        let threshold = max(silencePeak, peak * 0.06)
        guard let first = loudness.firstIndex(where: { $0 >= threshold }),
              let last = loudness.lastIndex(where: { $0 >= threshold }) else { return nil }

        let pad = Int(Double(sampleRate) * padding)
        let lower = max(0, first * frameLength - pad)
        let upper = min(samples.count, (last + 1) * frameLength + pad)
        return lower < upper ? lower..<upper : nil
    }
}
