import AudioToolbox
import AVFoundation
import CoreAudio

enum RecorderError: LocalizedError {
    case noMicrophone
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "I can't find a microphone."
        case .couldNotStart: return "The microphone didn't start."
        }
    }
}

/// Captures the microphone for the hold-to-talk key.
///
/// With `keepOpen` the microphone is opened once and stays open, so pressing the key does not
/// start anything: no wait for the first word, and no audio-route change that makes music
/// stutter or duck. While nobody is dictating, the last third of a second is kept in a small
/// rolling buffer and put in front of the dictation, so the very first word is never cut.
/// Without `keepOpen` the microphone is opened on the key press and closed afterwards.
///
/// Starting and stopping happen on one private queue, in order, so a quick tap can
/// never leave a dictation running.
final class AudioRecorder: @unchecked Sendable {
    /// How much audio from just before the key press goes in front of a dictation.
    static let preRollSeconds = 0.35

    private let queue = DispatchQueue(label: "com.stupidesigner.stupidtalk.audio")
    private var engine: AVAudioEngine?
    private var engineUsesBuiltIn = true
    private var configObserver: NSObjectProtocol?

    // Shared with the audio thread, always behind `lock`.
    private let lock = NSLock()
    private var collector: SampleCollector?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var ring: [Float] = []
    private let resampler = Resampler()

    /// Opens the microphone without starting a dictation, so the next key press is instant.
    /// Does nothing when it is already open the same way or a dictation is running.
    func warmUp(preferBuiltInMicrophone: Bool) {
        queue.async {
            self.lock.lock()
            let busy = self.collector != nil
            self.lock.unlock()
            if busy { return }
            if let engine = self.engine, engine.isRunning, self.engineUsesBuiltIn == preferBuiltInMicrophone { return }
            try? self.startOnQueue(preferBuiltInMicrophone: preferBuiltInMicrophone)
        }
    }

    /// Closes the microphone when no dictation is running. For when "Instant start" is switched off.
    func coolDown() {
        queue.async {
            self.lock.lock()
            let busy = self.collector != nil
            self.lock.unlock()
            if !busy { self.stopOnQueue() }
        }
    }

    /// Starts filling `collector` with 16 kHz samples. `onLevel` is called on the audio thread.
    /// `completion` is called on the main thread.
    func start(
        preferBuiltInMicrophone: Bool,
        into collector: SampleCollector,
        onLevel: @escaping @Sendable (Float) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async {
            do {
                let warm = self.engine?.isRunning == true && self.engineUsesBuiltIn == preferBuiltInMicrophone
                if !warm {
                    try self.startOnQueue(preferBuiltInMicrophone: preferBuiltInMicrophone)
                }
                self.lock.lock()
                if warm {
                    collector.append(self.ring)
                }
                self.ring.removeAll(keepingCapacity: true)
                self.collector = collector
                self.levelHandler = onLevel
                self.lock.unlock()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Keeps listening for `tail` seconds after the key came up, because people let go a moment
    /// before the last word is really finished. `completion` is called on the main thread as soon
    /// as no more audio is wanted. With `keepOpen` the microphone stays open for the next time.
    func stop(tail: TimeInterval = 0, keepOpen: Bool = false, completion: @escaping @Sendable () -> Void) {
        let work = {
            self.lock.lock()
            self.collector = nil
            self.levelHandler = nil
            self.ring.removeAll(keepingCapacity: true)
            self.lock.unlock()
            DispatchQueue.main.async { completion() }
            if !keepOpen { self.stopOnQueue() }
        }
        if tail > 0 {
            queue.asyncAfter(deadline: .now() + tail, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private func startOnQueue(preferBuiltInMicrophone: Bool) throws {
        stopOnQueue()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if preferBuiltInMicrophone, let device = AudioDevices.builtInMicrophone(), let unit = input.audioUnit {
            var deviceID = device
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Log.info("Could not pick this Mac's microphone (status \(status)). Using the system default.")
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noMicrophone
        }

        // No explicit format: the tap then always matches whatever the microphone delivers,
        // even right after the device was switched.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.couldNotStart(error.localizedDescription)
        }
        self.engine = engine
        self.engineUsesBuiltIn = preferBuiltInMicrophone
        // A device change (AirPods connecting, a mic plugged in) stops the engine. The app
        // notices and opens it again within a couple of seconds.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            Log.info("The audio device changed. The microphone will be opened again.")
        }
    }

    /// Runs on the audio thread for every buffer the microphone delivers.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        let samples = resampler.convert(buffer)
        lock.lock()
        let target = collector
        let level = levelHandler
        if target == nil {
            ring.append(contentsOf: samples)
            let limit = Int(16_000 * Self.preRollSeconds)
            if ring.count > limit { ring.removeFirst(ring.count - limit) }
        }
        lock.unlock()
        if let target {
            target.append(samples)
            level?(AudioRecorder.level(of: buffer))
        }
    }

    private func stopOnQueue() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Loudness of one buffer, squeezed into 0...1 for the little level bars.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        // Roughly -50 dB (quiet room) to -12 dB (clear speech).
        return min(1, max(0, (decibels + 50) / 38))
    }
}

/// Finds the microphone built into the Mac, so AirPods can stay in music mode.
enum AudioDevices {
    static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        for device in devices where transport(of: device) == kAudioDeviceTransportTypeBuiltIn && inputChannels(of: device) > 0 {
            return device
        }
        return nil
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in list {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }
}

/// Turns microphone audio into what the speech model wants: mono, 16 kHz, 32-bit float.
/// Used from the audio thread only, one per dictation.
final class Resampler {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let target = Self.format
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // No priming: priming swallows the first few milliseconds, and with them a first word.
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Collects the 16 kHz samples of one dictation. Written from the audio thread, read once at the end.
final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    init() {
        samples.reserveCapacity(16_000 * 30)
    }

    func append(_ more: [Float]) {
        guard !more.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: more)
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
