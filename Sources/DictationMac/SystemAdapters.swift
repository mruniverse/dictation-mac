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

/// The slice of AVAudioEngine that capture drives; a seam so the guards run against a double.
@MainActor
protocol CaptureEngine: AnyObject {
    /// Sender of this engine's `.AVAudioEngineConfigurationChange`.
    var configurationChangeSender: AnyObject { get }
    /// Input node, input bus 0: the hardware format; zero channels or rate means input is unavailable.
    var hardwareFormat: AVAudioFormat { get }
    /// Input node, output bus 0: the format a tap installed with a nil format receives.
    var tapFormat: AVAudioFormat { get }
    /// Points the input unit at `device`; false when the unit refuses it.
    func selectInputDevice(_ device: AudioDeviceID) -> Bool
    /// The device the input unit reports, read back from it; nil when the query fails.
    func currentInputDevice() -> AudioDeviceID?
    func installTap(_ block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func start() throws
    func stop()
}

/// Chosen (or default) input device through AVAudioEngine; first channel only, kept in memory by
/// the caller. A chosen device is confirmed by reading it back from the running unit, before the
/// first block and again before each block is delivered; a mismatch or failed read stops capture
/// with `.selectedDeviceUnavailable` instead of falling back to another input.
///
/// Each start opens a generation and `stop()` closes it before tearing anything down, so blocks
/// and configuration changes still queued from an earlier engine are dropped. A configuration
/// change only hops to the main queue: AVAudioEngine.h forbids tearing the engine down inside
/// that notification. Nothing orders the hop before a stop already queued on the main queue: a
/// clip submitted first keeps the earlier blocks (device ID checked at delivery, not capture).
@MainActor
final class EngineAudioCapture: AudioCapture {
    private let inputUID: @MainActor () -> String?
    private let deviceID: @MainActor (String) -> AudioDeviceID?
    private let makeEngine: @MainActor () -> CaptureEngine
    private var engine: CaptureEngine?
    private var configurationObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    /// Opens only once the current generation's device is confirmed.
    private var delivering = false

    init(
        inputUID: @escaping @MainActor () -> String? = { nil },
        deviceID: @escaping @MainActor (String) -> AudioDeviceID? = { CoreAudioInputDevices().deviceID(forUID: $0) },
        makeEngine: @escaping @MainActor () -> CaptureEngine = { SystemCaptureEngine() }
    ) {
        self.inputUID = inputUID
        self.deviceID = deviceID
        self.makeEngine = makeEngine
    }

    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws {
        stop()
        let current = generation
        let chosenID: AudioDeviceID?
        if let uid = inputUID() {
            guard let id = deviceID(uid) else { throw CaptureFailure.selectedDeviceUnavailable }
            chosenID = id
        } else {
            chosenID = nil
        }
        let engine = makeEngine()
        self.engine = engine
        if let chosenID, !engine.selectInputDevice(chosenID) { throw abandon(.selectedDeviceUnavailable) }
        let hardware = engine.hardwareFormat
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            throw abandon(chosenID == nil ? .noInputDevice : .selectedDeviceUnavailable)
        }
        let tapFormat = engine.tapFormat
        guard tapFormat.sampleRate == hardware.sampleRate, tapFormat.channelCount == hardware.channelCount,
              Self.tapCanRead(tapFormat) else { throw abandon(.engineFailure) }
        engine.installTap(Self.tap(delivering: { [weak self] chunk in
            self?.deliver(chunk, generation: current, chosenID: chosenID, onChunk: onChunk, onFailure: onFailure)
        }))
        // Posted on the engine's internal queue. A `.main` observer would make that queue wait for
        // the main thread, which may itself be stopping the engine; only hop, never tear down here.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine.configurationChangeSender, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.configurationChanged(generation: current, onFailure: onFailure) }
            }
        }
        do {
            try engine.start()
        } catch {
            throw abandon(.engineFailure)
        }
        // The unit may run another device than the one set before start; nothing is delivered until
        // it reports the chosen one. Outside the `catch` above, so this failure is not normalized.
        if let chosenID, engine.currentInputDevice() != chosenID { throw abandon(.selectedDeviceUnavailable) }
        delivering = true
    }

    func stop() {
        // Invalidate first: whatever this engine already queued for the main actor is dropped.
        generation &+= 1
        delivering = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.removeTap()
        engine?.stop()
        engine = nil
    }

    private func abandon(_ failure: CaptureFailure) -> CaptureFailure {
        stop()
        return failure
    }

    private func isLive(_ id: UInt64) -> Bool { delivering && generation == id }

    private func deliver(
        _ chunk: AudioChunk,
        generation id: UInt64,
        chosenID: AudioDeviceID?,
        onChunk: @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @Sendable @MainActor (CaptureFailure) -> Void
    ) {
        guard isLive(id) else { return }
        // The block may come from another device if the unit switched since start: drop it and stop.
        if let chosenID, engine?.currentInputDevice() != chosenID {
            stop()
            return onFailure(.selectedDeviceUnavailable)
        }
        onChunk(chunk)
    }

    /// Runs from the main queue after the notification callback returned.
    private func configurationChanged(
        generation id: UInt64,
        onFailure: @Sendable @MainActor (CaptureFailure) -> Void
    ) {
        guard isLive(id) else { return }
        // AVAudioEngine has already stopped itself; release it and report.
        stop()
        onFailure(.deviceChanged)
    }

    /// The tap reads `floatChannelData[0]` as `frameLength` contiguous samples: Float32 with a
    /// non-interleaved layout, or a single channel (stride 1). Anything else would read garbage or nil.
    private static func tapCanRead(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && format.channelCount > 0
            && format.sampleRate > 0
            && (format.channelCount == 1 || !format.isInterleaved)
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

/// AVAudioEngine behind `CaptureEngine`; only its input node is used. The device is set and read
/// through the input unit's `kAudioOutputUnitProperty_CurrentDevice`.
@MainActor
final class SystemCaptureEngine: CaptureEngine {
    private let engine = AVAudioEngine()
    private var hasTap = false

    var configurationChangeSender: AnyObject { engine }
    var hardwareFormat: AVAudioFormat { engine.inputNode.inputFormat(forBus: 0) }
    var tapFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func selectInputDevice(_ device: AudioDeviceID) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    func currentInputDevice() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr,
              size == UInt32(MemoryLayout<AudioDeviceID>.size),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    func installTap(_ block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: block)
        hasTap = true
    }

    func removeTap() {
        guard hasTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        hasTap = false
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}
