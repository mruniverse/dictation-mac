import Foundation

/// The menu's cloud settings, and the only code that touches the Keychain: on the user's explicit
/// load, save or removal, never otherwise. Launching, opening the menu, recording and sending
/// neither look the key up nor read it; clips use the key kept in memory for this run. Consent and
/// key stay separate: saving or loading a key never grants consent, revoking never deletes or
/// forgets the key. Withdrawing either takes effect at once: a clip waiting for its first-send
/// question or its request is stopped and discarded, unsent. Keychain calls run on the keychain
/// queue, never on the main thread.
@MainActor
public final class CloudSettings {
    /// What the last explicit load, save or removal left in memory; reading it touches nothing.
    public var keyStatus: APIKeyStatus { session.status }
    /// A load, save or removal is waiting on the Keychain, which may be showing its own dialog.
    public var isWaitingForKeychain: Bool { pending > 0 }
    /// Called after the key status, the wait or the consent changed here.
    public var onChange: (() -> Void)?
    public let consent: CloudConsent

    private let keys: any APIKeyStore
    private let queue: KeychainQueue
    private let gate: ConsentGatedTranscriber
    private let session: SessionAPIKey
    private var pending = 0
    /// Counts removals: a load or save asked before the latest one never fills memory or reports an error.
    private var removals = 0

    init(
        consent: CloudConsent,
        keys: any APIKeyStore,
        queue: KeychainQueue,
        gate: ConsentGatedTranscriber,
        session: SessionAPIKey
    ) {
        self.consent = consent
        self.keys = keys
        self.queue = queue
        self.gate = gate
        self.session = session
    }

    /// Explicit user action only.
    public func grantConsent() {
        consent.grant()
        onChange?()
    }

    /// Withdraws consent and the first-send confirmation; the clip on its way is discarded. Keeps the key.
    public func revokeConsent() {
        consent.revoke()
        gate.refuseAll(.consentRequired)
        onChange?()
    }

    /// Explicit user action only: reads this app's item once, on the keychain queue — the system may
    /// ask to allow it — and keeps the key in memory for this run. No saved key reads as `.missing`;
    /// a refusal as `.unavailable`, unless a key is already in memory, which then stays.
    /// `completion` gets the keychain failure, if any; nil if a removal overtook the load.
    public func loadKey(completion: @escaping @Sendable @MainActor (KeychainError?) -> Void) {
        perform({ try $0.read() }, completion: completion, unlessRemoved: true) { [session] result in
            switch result {
            case let .success(key?):
                session.hold(key)
            case .success(nil):
                session.forget(.missing)
            case let .failure(failure):
                if session.key == nil { session.forget(.unavailable(failure)) }
                return failure
            }
            return nil
        }
    }

    /// Saves the key, then keeps it in memory for this run without reading it back. A failed save
    /// changes nothing. `completion` gets the keychain failure, if any; nil if a removal
    /// overtook the save, whose key then stays out of memory (the queued delete follows it).
    public func saveKey(_ key: OpenAIAPIKey, completion: @escaping @Sendable @MainActor (KeychainError?) -> Void) {
        perform({ try $0.save(key) }, completion: completion, unlessRemoved: true) { [session] result in
            guard case let .failure(failure) = result else {
                session.hold(key)
                return nil
            }
            return failure
        }
    }

    /// Forgets this run's key, revokes consent and stops the clip on its way, at once — even if the
    /// Keychain then refuses to delete the item. `completion` gets the keychain failure, if any.
    public func removeKey(completion: @escaping @Sendable @MainActor (KeychainError?) -> Void) {
        removals += 1
        session.forget(.notLoaded)
        consent.revoke()
        perform(
            { try $0.delete() }, completion: completion, unlessRemoved: false,
            afterEnqueue: { gate.refuseAll(.missingCredential) }
        ) { [session] result in
            guard case let .failure(failure) = result else {
                if session.key == nil { session.forget(.missing) }
                return nil
            }
            return failure
        }
    }

    /// Runs `operation` on the keychain queue; `apply` updates memory from its result on the main
    /// actor and returns the failure to report. With `unlessRemoved`, a result that arrives after a
    /// later removal is dropped: it changes nothing and reports no failure.
    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (any APIKeyStore) throws -> T,
        completion: @escaping @Sendable @MainActor (KeychainError?) -> Void,
        unlessRemoved: Bool,
        afterEnqueue: @MainActor () -> Void = {},
        apply: @escaping @MainActor (Result<T, KeychainError>) -> KeychainError?
    ) {
        let asked = removals
        pending += 1
        let receive: @MainActor (Result<T, KeychainError>) -> Void = { [weak self] result in
            guard let self else { return }
            self.pending -= 1
            let overtaken = unlessRemoved && asked != self.removals
            let failure = overtaken ? nil : apply(result)
            self.onChange?()
            completion(failure)
        }
        // Enqueue before notifying anyone who could synchronously request another operation.
        // Some queues deliver inline; publish their result only after the removal cancels old sends.
        let delivery = EnqueuedResult<T>()
        queue.run({ [keys] in Result { try operation(keys) }.mapError(KeychainError.init) }) { result in
            if delivery.isReady { receive(result) } else { delivery.result = result }
        }
        afterEnqueue()
        delivery.isReady = true
        if let result = delivery.result { receive(result) } else { onChange?() }
    }
}

@MainActor
private final class EnqueuedResult<Value: Sendable> {
    var isReady = false
    var result: Result<Value, KeychainError>?
}

/// The API key for this run, in memory only: never written anywhere else and never described (the
/// key's own descriptions are redacted). Filled only by an explicit save or load; emptied by removal.
@MainActor
final class SessionAPIKey {
    private(set) var key: OpenAIAPIKey?
    private(set) var status = APIKeyStatus.notLoaded

    func hold(_ key: OpenAIAPIKey) {
        self.key = key
        status = .loaded
    }

    /// Drops the key; `reason` tells why there is none.
    func forget(_ reason: APIKeyStatus) {
        key = nil
        status = reason == .loaded ? .notLoaded : reason
    }
}
