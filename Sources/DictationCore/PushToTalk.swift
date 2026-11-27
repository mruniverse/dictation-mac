import Foundation

public enum PushToTalkStart: Equatable, Sendable {
    case accepted(UUID)
    case rejected
}

/// Future binding must atomically accept the proposed ID, never reuse a manual session.
/// Stop/cancel must also compare that ID atomically. No binding is installed by this module.
/// A held session must not auto-submit: its capture limit must discard, not call stop.
@MainActor
public protocol PushToTalkCapture: AnyObject, Sendable {
    var phase: CaptureController.Phase { get }
    var sessionID: UUID? { get }
    /// Install the proposal before returning `.accepted(proposal)`; rejection transfers no ownership.
    func start(proposing sessionID: UUID, deadline: ContinuousClock.Instant) -> PushToTalkStart
    func stop(session sessionID: UUID)
    func cancel(session sessionID: UUID)
}

public enum PushToTalkEvent: Sendable { case pressed, released }

/// Initially off. Activation requires an observed release before the first accepted press.
@MainActor
public final class PushToTalk {
    public private(set) var registration: UUID?
    public private(set) var isArmed = false
    public private(set) var isPressed = false
    private let capture: PushToTalkCapture
    private let scheduler: Scheduler
    private let maximumHold: TimeInterval
    private let now: @MainActor () -> ContinuousClock.Instant
    private let blocked: @MainActor () -> Bool
    private var ownedSession: UUID?
    private var gesture: (id: UUID, deadline: ContinuousClock.Instant)?

    /// Invalid deadlines (outside 0 < seconds <= 30) disable starts rather than remove the watchdog.
    public init(
        capture: PushToTalkCapture,
        scheduler: Scheduler,
        maximumHold: TimeInterval = 25,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        blocked: @escaping @MainActor () -> Bool = { false }
    ) {
        self.capture = capture
        self.scheduler = scheduler
        self.maximumHold = maximumHold
        self.now = now
        self.blocked = blocked
    }

    deinit {
        let capture = capture
        let id = ownedSession
        let cancel: @MainActor @Sendable () -> Void = {
            if let id, capture.sessionID == id, capture.phase != .idle { capture.cancel(session: id) }
        }
        if Thread.isMainThread { MainActor.assumeIsolated(cancel) }
        else { DispatchQueue.main.async { cancel() } }
    }

    /// Use a fresh adapter generation. Reconfiguration consumes a release, never assumes keys are up.
    public func activate(registration: UUID) {
        deactivate()
        self.registration = registration
    }

    /// Call on disable, suspension, registration error and shutdown. Never resumes automatically.
    public func deactivate() {
        registration = nil
        discard()
    }

    /// The future binding must forward every capture transition, including errors and timeouts.
    public func captureChanged() {
        guard let id = ownedSession else { return }
        if capture.sessionID != id || ![.awaitingPermission, .recording].contains(capture.phase) {
            discard()
        }
    }

    public func receive(_ event: PushToTalkEvent, registration: UUID) {
        guard self.registration == registration else { return }
        switch event {
        case .released:
            isPressed = false
            isArmed = true
            let id = ownedSession
            let deadline = gesture?.deadline
            ownedSession = nil
            gesture = nil
            guard let id, capture.sessionID == id else { return }
            switch capture.phase {
            case .awaitingPermission: capture.cancel(session: id)
            case .recording:
                if !blocked(), let deadline, now() < deadline { capture.stop(session: id) }
                else { capture.cancel(session: id) }
            case .idle, .processing: break
            }
        case .pressed:
            guard !isPressed else { return }
            isPressed = true
            let wasArmed = isArmed
            isArmed = false
            guard wasArmed, !blocked(), maximumHold.isFinite, maximumHold > 0, maximumHold <= 30,
                  capture.phase == .idle, capture.sessionID == nil else { return }
            let id = UUID()
            let deadline = now().advanced(by: .seconds(maximumHold))
            gesture = (id, deadline)
            scheduler.schedule(after: maximumHold) { [weak self] in
                guard let self, self.gesture?.id == id else { return }
                self.discard()
            }
            // An injected scheduler may invalidate the gesture before returning.
            guard gesture?.id == id, self.registration == registration, isPressed else { return }
            guard now() < deadline else { return discard() }
            guard capture.start(proposing: id, deadline: deadline) == .accepted(id), capture.sessionID == id else {
                if gesture?.id == id { gesture = nil }
                return
            }
            ownedSession = id
            guard gesture?.id == id, self.registration == registration, isPressed, now() < deadline,
                  [.awaitingPermission, .recording].contains(capture.phase) else { return discard() }
        }
    }

    private func discard() {
        let id = ownedSession
        ownedSession = nil
        gesture = nil
        isArmed = false
        if let id, capture.sessionID == id, capture.phase != .idle {
            capture.cancel(session: id)
        }
    }
}
