import AVFoundation
import DictationCore
import AudioToolbox

/// Prompts only when the status is undetermined, i.e. after the user chose Iniciar.
struct SystemMicrophonePermission: MicrophonePermission {
    func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: Task { @MainActor in completion(await AVCaptureDevice.requestAccess(for: .audio)) }
        default: completion(false)
        }
    }
}

struct MainQueueScheduler: Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
    }
}

/// Default input device through AVAudioEngine; first channel only, kept in memory by the caller.
@MainActor
final class EngineAudioCapture: AudioCapture {
    private let inputUID: @MainActor () -> String?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    init(inputUID: @escaping @MainActor () -> String? = { nil }) {
        self.inputUID = inputUID
    }

    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws {
        stop()
        let engine = try Self.makeEngine(inputUID: inputUID())
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.tap(delivering: onChunk))
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onFailure(.deviceChanged) }
        }
        self.engine = engine
        do {
            try engine.start()
        } catch {
            stop()
            throw CaptureFailure.engineFailure
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    static func makeEngine(inputUID: String?) throws -> AVAudioEngine {
        let selectedID: AudioDeviceID?
        if let inputUID {
            guard let id = CoreAudioInputDevices().deviceID(forUID: inputUID) else {
                throw CaptureFailure.selectedDeviceUnavailable
            }
            selectedID = id
        } else {
            selectedID = nil
        }
        let engine = AVAudioEngine()
        if let selectedID {
            let unit = engine.inputNode.audioUnit
            var id = selectedID
            guard let unit, AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            ) == noErr else { throw CaptureFailure.selectedDeviceUnavailable }
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureFailure.noInputDevice }
        return engine
    }

    /// Runs on the real-time audio thread, so it must stay nonisolated and only copy samples.
    private nonisolated static func tap(
        delivering onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let chunk = AudioChunk(samples: samples, sampleRate: buffer.format.sampleRate)
            DispatchQueue.main.async { MainActor.assumeIsolated { onChunk(chunk) } }
        }
    }
}
