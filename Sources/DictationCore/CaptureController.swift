import Foundation

/// Capture session started from the menu (manual) or by the push-to-talk gesture, with every late
/// callback filtered by session. A held session ends unsent at its monotonic deadline: only its own
/// release, before the deadline, may submit it; the menu's Parar and the automatic stop never do.
@MainActor
public final class CaptureController {
    public enum Phase: Equatable, Sendable {
        case idle
        case awaitingPermission
        case recording
        case processing
    }

    public enum Origin: Equatable, Sendable {
        /// Iniciar in the menu: Parar or the automatic stop at the capture limit submit the clip.
        case manual
        /// Held shortcut: only `stop(session:)` before the deadline submits; anything later discards.
        case pushToTalk
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sessionID: UUID?
    public private(set) var origin: Origin?
    public private(set) var lastOutcome: Outcome?
    public var onChange: (() -> Void)?

    private let permission: MicrophonePermission
    private let capture: AudioCapture
    private let scheduler: Scheduler
    private let transcriber: Transcriber?
    private let limits: CaptureLimits
    private let now: @MainActor () -> ContinuousClock.Instant

    private var deadline: ContinuousClock.Instant?
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var loudestRMS: Float = 0
    /// Request of the current session; cancelled whenever the session ends without its result.
    private var inFlight: TranscriptionCancellation?
    private var duration: TimeInterval { sampleRate.map { Double(samples.count) / $0 } ?? 0 }

    /// `now` must be the same monotonic clock as the gesture's, so both agree on its deadline.
    public init(
        permission: MicrophonePermission,
        capture: AudioCapture,
        scheduler: Scheduler,
        transcriber: Transcriber? = nil,
        limits: CaptureLimits = CaptureLimits(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.permission = permission
        self.capture = capture
        self.scheduler = scheduler
        self.transcriber = transcriber
        self.limits = limits
        self.now = now
    }

    public func start() {
        guard phase == .idle else { return }
        begin(UUID(), origin: .manual, deadline: nil)
    }

    /// Opens a held session under the gesture's ID, only while idle and before its deadline.
    public func start(proposing id: UUID, deadline: ContinuousClock.Instant) -> PushToTalkStart {
        guard phase == .idle, sessionID == nil, now() < deadline else { return .rejected }
        begin(id, origin: .pushToTalk, deadline: deadline)
        return .accepted(id)
    }

    /// Parar in the menu: ends a manual recording only; a held session waits for its release.
    public func stop() {
        guard phase == .recording, origin == .manual else { return }
        submit()
    }

    /// Release of the held session `id`: submits only before its deadline; at or after it, discards.
    /// Before access was granted, discards. Another session, or a manual one, is left alone.
    public func stop(session id: UUID) {
        guard sessionID == id, origin == .pushToTalk else { return }
        switch phase {
        case .awaitingPermission: abort(isExpired ? .pushToTalkExpired : .cancelled)
        case .recording: if isExpired { abort(.pushToTalkExpired) } else { submit() }
        case .idle, .processing: break
        }
    }

    /// Discards the held session `id`; another session, or a manual one, is left alone.
    public func cancel(session id: UUID) {
        guard sessionID == id, origin == .pushToTalk else { return }
        abort(isExpired ? .pushToTalkExpired : .cancelled)
    }

    public func cancel() { abort(.cancelled) }

    public func suspend() { abort(.suspended) }

    private func begin(_ id: UUID, origin: Origin, deadline: ContinuousClock.Instant?) {
        sessionID = id
        self.origin = origin
        self.deadline = deadline
        lastOutcome = nil
        transition(to: .awaitingPermission)
        // The observer may have ended the session; a cancelled session must not show the system prompt.
        guard isCurrent(id, .awaitingPermission) else { return }
        permission.requestAccess { [weak self] granted in self?.permissionAnswered(granted, session: id) }
    }

    /// Ends the recording and hands the clip to the transcriber.
    private func submit() {
        capture.stop()
        let measured = duration
        if measured < limits.minDuration { return end(.discarded(.tooShort, duration: measured)) }
        if loudestRMS < limits.silenceRMS { return end(.discarded(.silent, duration: measured)) }
        guard let transcriber, let sampleRate, let id = sessionID else {
            return end(.discarded(.transcriptionUnavailable, duration: measured))
        }
        let audio = CapturedAudio(samples: samples, sampleRate: sampleRate)
        transition(to: .processing)
        // The observer may cancel, suspend or even start the next session from inside the notification.
        guard isCurrent(id, .processing) else { return }
        scheduler.schedule(after: limits.processingTimeout) { [weak self] in
            guard let self, self.isCurrent(id, .processing) else { return }
            self.end(.discarded(.transcriptionTimedOut, duration: measured))
        }
        // A scheduler may run an already-due deadline synchronously.
        guard isCurrent(id, .processing) else { return }
        let request = PendingRequest()
        let handle = transcriber.transcribe(audio) { [weak self] result in
            request.answered = true
            guard let self, self.isCurrent(id, .processing) else { return }
            self.inFlight = nil
            switch result {
            case let .success(text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                self.end(.discarded(.transcriptionEmpty, duration: measured))
            case let .success(text): self.end(.transcribed(text, duration: measured))
            case let .failure(error):
                self.end(.discarded(DiscardReason(transcriptionFailure: error), duration: measured))
            }
        }
        if isCurrent(id, .processing) {
            inFlight = handle
        } else if !request.answered {
            // The session ended inside `transcribe` without this request's result: nothing else owns it.
            handle.cancel()
        }
        // Otherwise it answered synchronously and is finished; a later session must never cancel it.
    }

    private func permissionAnswered(_ granted: Bool, session id: UUID) {
        guard isCurrent(id, .awaitingPermission) else { return }
        guard granted else { return end(.discarded(.permissionDenied, duration: 0)) }
        // A grant answered after the gesture's deadline must not open the microphone.
        guard !isExpired else { return end(.discarded(.pushToTalkExpired, duration: 0)) }
        do {
            try capture.start(
                onChunk: { [weak self] chunk in self?.receive(chunk, session: id) },
                onFailure: { [weak self] failure in self?.captureFailed(failure, session: id) }
            )
        } catch {
            return end(.discarded(.capture(error as? CaptureFailure ?? .engineFailure), duration: 0))
        }
        // Opening the device takes time; the deadline may have passed meanwhile.
        guard !isExpired else { return end(.discarded(.pushToTalkExpired, duration: 0)) }
        transition(to: .recording)
        if origin == .pushToTalk, let deadline {
            // Held: the watchdog discards at the deadline (or the capture limit); it never submits.
            let delay = min(limits.maxDuration, Self.seconds(deadline - now()))
            scheduler.schedule(after: delay) { [weak self] in
                guard let self, self.isCurrent(id, .recording) else { return }
                self.end(.discarded(.pushToTalkExpired, duration: self.duration))
            }
        } else {
            scheduler.schedule(after: limits.maxDuration) { [weak self] in
                guard let self, self.isCurrent(id, .recording) else { return }
                self.stop()
            }
        }
    }

    private func receive(_ chunk: AudioChunk, session id: UUID) {
        guard isCurrent(id, .recording), !chunk.samples.isEmpty else { return }
        // Audio of a held session past its deadline ends it, even if the watchdog has not run yet.
        if isExpired { return end(.discarded(.pushToTalkExpired, duration: duration)) }
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
        origin = nil
        deadline = nil
        // Cancelled only after the session is invalidated, so a synchronous answer is filtered out.
        let pending = inFlight
        inFlight = nil
        pending?.cancel()
        lastOutcome = outcome
        transition(to: .idle)
    }

    /// A held session at or past its deadline; never true for a manual session.
    private var isExpired: Bool {
        guard origin == .pushToTalk else { return false }
        guard let deadline else { return true }
        return now() >= deadline
    }

    private func isCurrent(_ id: UUID, _ expected: Phase) -> Bool {
        sessionID == id && phase == expected
    }

    private func transition(to next: Phase) {
        phase = next
        onChange?()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return max(0, Double(seconds) + Double(attoseconds) / 1e18)
    }
}

extension CaptureController: PushToTalkCapture {}

/// Whether a request already reported, even to a session that had ended.
@MainActor
private final class PendingRequest {
    var answered = false
}
