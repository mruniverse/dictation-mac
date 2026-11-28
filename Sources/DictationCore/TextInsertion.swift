import Foundation

/// Token of a destination lock acquired by the integrator on an accepted push-to-talk press.
public struct TextInsertionLock: Equatable, Sendable {
    public let token: UUID

    public init(token: UUID) {
        self.token = token
    }
}

public enum TextInsertionResult: Equatable, Sendable {
    case inserted
    case unconfirmed
    case notInserted
}

@MainActor
public protocol TextInsertionTarget: AnyObject {
    func insert(_ text: String, into lock: TextInsertionLock) -> TextInsertionResult
    func release(_ lock: TextInsertionLock)
}

/// Per-session insertion policy: one bound lock at a time, consumed before any insertion attempt,
/// released exactly once, and never retried. Holds no transcript after `finish`.
@MainActor
public final class TextInsertionCoordinator {
    private static let maxUTF16Length = 10_000

    private let target: any TextInsertionTarget
    private var bound: (lock: TextInsertionLock, session: UUID)?

    public private(set) var isEnabled: Bool = false

    public init(target: any TextInsertionTarget) {
        self.target = target
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            invalidate()
        }
    }

    /// Binds a lock acquired by the integrator to an accepted push-to-talk session.
    /// While disabled the new lock is released at once; replacing a bound lock releases the previous one.
    public func bind(_ lock: TextInsertionLock, to session: UUID) {
        guard isEnabled else {
            target.release(lock)
            return
        }
        let previous = bound?.lock
        bound = (lock, session)
        if let previous, previous != lock {
            target.release(previous)
        }
    }

    /// Releases the currently bound lock, if any. Never affects a session bound later.
    public func invalidate() {
        guard let current = bound else { return }
        bound = nil
        target.release(current.lock)
    }

    /// Ends a session. A different session ID leaves the bound lock untouched. A matching ID consumes the
    /// lock before any callback and releases it exactly once; only an enabled push-to-talk transcript
    /// is inserted, and the target's result is returned without retry.
    @discardableResult
    public func finish(session: UUID, origin: CaptureController.Origin, outcome: Outcome) -> TextInsertionResult? {
        guard let current = bound, current.session == session else { return nil }
        bound = nil
        defer { target.release(current.lock) }

        guard isEnabled, origin == .pushToTalk,
              case let .transcribed(text, _) = outcome,
              let clean = Self.sanitize(text) else { return nil }
        return target.insert(clean, into: current.lock)
    }

    /// Replaces line and tab separators with a single space (CRLF counts once), removes remaining C0/C1
    /// controls, DEL and explicit bidi embeddings/isolates, trims edges, and rejects empty or over-long text.
    private static func sanitize(_ input: String) -> String? {
        guard input.utf16.count <= maxUTF16Length else { return nil }

        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0D:
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A {
                    index += 1
                }
                output.append(" ")
            case 0x0A, 0x09, 0x2028, 0x2029:
                output.append(" ")
            case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x202A...0x202E, 0x2066...0x2069:
                break
            default:
                output.unicodeScalars.append(scalar)
            }
            index += 1
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maxUTF16Length else { return nil }
        return trimmed
    }
}
