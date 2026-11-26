import Foundation

/// Manual capture session: start, stop or cancel, with every late callback filtered by session.
@MainActor
public final class CaptureController {
    public enum Phase: Equatable, Sendable {
        case idle
        case awaitingPermission
        case recording
        case processing
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sessionID: UUID?
    public private(set) var lastOutcome: Outcome?
    public var onChange: (() -> Void)?

    private let permission: MicrophonePermission
    private let capture: AudioCapture
    private let scheduler: Scheduler
    private let transcriber: Transcriber?
    private let limits: CaptureLimits

    private var samples: [Float] = []
    private var sampleRate: Double?
    private var loudestRMS: Float = 0
    private var duration: TimeInterval { sampleRate.map { Double(samples.count) / $0 } ?? 0 }

    public init(
        permission: MicrophonePermission,
        capture: AudioCapture,
        scheduler: Scheduler,
        transcriber: Transcriber? = nil,
        limits: CaptureLimits = CaptureLimits()
    ) {
        self.permission = permission
        self.capture = capture
        self.scheduler = scheduler
        self.transcriber = transcriber
        self.limits = limits
    }

    public func start() {
        guard phase == .idle else { return }
        let id = UUID()
        sessionID = id
        lastOutcome = nil
        transition(to: .awaitingPermission)
        permission.requestAccess { [weak self] granted in self?.permissionAnswered(granted, session: id) }
    }

    public func stop() {
        guard phase == .recording else { return }
        capture.stop()
        let measured = duration
        if measured < limits.minDuration { return end(.discarded(.tooShort, duration: measured)) }
        if loudestRMS < limits.silenceRMS { return end(.discarded(.silent, duration: measured)) }
        guard let transcriber, let sampleRate, let id = sessionID else {
            return end(.discarded(.transcriptionUnavailable, duration: measured))
        }
        transition(to: .processing)
        scheduler.schedule(after: limits.processingTimeout) { [weak self] in
            guard let self, self.isCurrent(id, .processing) else { return }
            self.end(.discarded(.transcriptionTimedOut, duration: measured))
        }
        transcriber.transcribe(CapturedAudio(samples: samples, sampleRate: sampleRate)) { [weak self] result in
            guard let self, self.isCurrent(id, .processing) else { return }
            switch result {
            case let .success(text): self.end(.transcribed(text, duration: measured))
            case .failure: self.end(.discarded(.transcriptionFailed, duration: measured))
            }
        }
    }

    public func cancel() { abort(.cancelled) }

    public func suspend() { abort(.suspended) }

    private func permissionAnswered(_ granted: Bool, session id: UUID) {
        guard isCurrent(id, .awaitingPermission) else { return }
        guard granted else { return end(.discarded(.permissionDenied, duration: 0)) }
        do {
            try capture.start(
                onChunk: { [weak self] chunk in self?.receive(chunk, session: id) },
                onFailure: { [weak self] failure in self?.captureFailed(failure, session: id) }
            )
        } catch {
            return end(.discarded(.capture(error as? CaptureFailure ?? .engineFailure), duration: 0))
        }
        transition(to: .recording)
        scheduler.schedule(after: limits.maxDuration) { [weak self] in
            guard let self, self.isCurrent(id, .recording) else { return }
            self.stop()
        }
    }

    private func receive(_ chunk: AudioChunk, session id: UUID) {
        guard isCurrent(id, .recording), !chunk.samples.isEmpty else { return }
        if let sampleRate, sampleRate != chunk.sampleRate { return captureFailed(.deviceChanged, session: id) }
        sampleRate = chunk.sampleRate
        samples += chunk.samples
        let energy = chunk.samples.reduce(Float(0)) { $0 + $1 * $1 }
        loudestRMS = max(loudestRMS, (energy / Float(chunk.samples.count)).squareRoot())
    }

    private func captureFailed(_ failure: CaptureFailure, session id: UUID) {
        guard isCurrent(id, .recording) else { return }
        end(.discarded(.capture(failure), duration: duration))
    }

    private func abort(_ reason: DiscardReason) {
        guard phase != .idle else { return }
        end(.discarded(reason, duration: duration))
    }

    private func end(_ outcome: Outcome) {
        capture.stop()
        samples = []
        sampleRate = nil
        loudestRMS = 0
        sessionID = nil
        lastOutcome = outcome
        transition(to: .idle)
    }

    private func isCurrent(_ id: UUID, _ expected: Phase) -> Bool {
        sessionID == id && phase == expected
    }

    private func transition(to next: Phase) {
        phase = next
        onChange?()
    }
}
