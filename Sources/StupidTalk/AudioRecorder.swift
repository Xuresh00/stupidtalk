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

/// Captures the microphone while the hold-to-talk key is down.
///
/// Starting and stopping happen on one private queue, in order, so a quick tap can
/// never leave the microphone running.
final class AudioRecorder {
    private let queue = DispatchQueue(label: "com.stupidesigner.stupidtalk.audio")
    private var engine: AVAudioEngine?

    /// `onBuffer` and `onLevel` are called on the audio thread. `completion` is called on the main thread.
    func start(
        preferBuiltInMicrophone: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async {
            do {
                try self.startOnQueue(preferBuiltInMicrophone: preferBuiltInMicrophone, onBuffer: onBuffer, onLevel: onLevel)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// `completion` is called on the main thread once the microphone is really off.
    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.stopOnQueue()
            DispatchQueue.main.async { completion() }
        }
    }

    private func startOnQueue(
        preferBuiltInMicrophone: Bool,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
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
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            onLevel(AudioRecorder.level(of: buffer))
            onBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.couldNotStart(error.localizedDescription)
        }
        self.engine = engine
    }

    private func stopOnQueue() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
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
