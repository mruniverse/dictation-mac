import AVFoundation
import DictationCore

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
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureFailure.noInputDevice }
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
