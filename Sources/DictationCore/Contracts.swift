import Foundation

/// Mono PCM block delivered by the capture device.
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Audio of one finished session, held only in memory.
public struct CapturedAudio: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

public enum CaptureFailure: Error, Equatable, Sendable {
    case noInputDevice
    case deviceChanged
    case engineFailure
}

@MainActor
public protocol MicrophonePermission {
    /// Answers with the current decision; only an undetermined status may show the system prompt.
    func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void)
}

@MainActor
public protocol AudioCapture: AnyObject {
    /// Starts the device. Callbacks may arrive after `stop()`; the caller filters them.
    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws
    /// Releases the device. Must be idempotent.
    func stop()
}

@MainActor
public protocol Scheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void)
}

@MainActor
public protocol Transcriber {
    func transcribe(_ audio: CapturedAudio, completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void)
}

public struct CaptureLimits: Sendable {
    public var minDuration: TimeInterval = 0.5
    public var maxDuration: TimeInterval = 30
    /// Loudest block below this RMS (about -50 dBFS) counts as silence; provisional until calibrated.
    public var silenceRMS: Float = 0.003
    public var processingTimeout: TimeInterval = 30

    public init() {}
}

public enum DiscardReason: Equatable, Sendable {
    case cancelled
    case suspended
    case permissionDenied
    case capture(CaptureFailure)
    case tooShort
    case silent
    case transcriptionUnavailable
    case transcriptionTimedOut
    case transcriptionFailed
}

public enum Outcome: Equatable, Sendable {
    case discarded(DiscardReason, duration: TimeInterval)
    case transcribed(String, duration: TimeInterval)

    public var message: String {
        let text: String
        let duration: TimeInterval
        switch self {
        case let .transcribed(transcript, measured):
            text = transcript
            duration = measured
        case let .discarded(reason, measured):
            text = reason.message
            duration = measured
        }
        guard duration > 0 else { return text }
        return text + " (" + String(format: "%.1f", duration).replacingOccurrences(of: ".", with: ",") + " s)"
    }
}

extension DiscardReason {
    var message: String {
        switch self {
        case .cancelled: "Cancelado — áudio descartado"
        case .suspended: "Sistema suspenso — áudio descartado"
        case .permissionDenied: "Microfone não autorizado — libere em Ajustes do Sistema › Privacidade e Segurança › Microfone"
        case .capture(.noInputDevice): "Nenhum microfone disponível"
        case .capture(.deviceChanged): "Dispositivo de áudio mudou — áudio descartado"
        case .capture(.engineFailure): "Falha na captura — áudio descartado"
        case .tooShort: "Gravação curta demais — áudio descartado"
        case .silent: "Silêncio — áudio descartado"
        case .transcriptionUnavailable: "Transcrição não configurada — áudio descartado"
        case .transcriptionTimedOut: "Transcrição excedeu o prazo — áudio descartado"
        case .transcriptionFailed: "Falha na transcrição — áudio descartado"
        }
    }
}
