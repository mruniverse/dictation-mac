import Foundation

/// The menu's cloud settings. Consent and key stay separate: saving a key never grants consent,
/// revoking never deletes the key. Withdrawing either takes effect at once: a clip waiting for its
/// key lookup, its first-send question or its request is stopped and discarded, unsent. Keychain
/// calls run on the keychain queue, never on the main thread.
@MainActor
public final class CloudSettings {
    public private(set) var keyStatus = APIKeyStatus.unknown
    /// Called after the key status or the consent changed here.
    public var onChange: (() -> Void)?
    public let consent: CloudConsent

    private let keys: any APIKeyStore
    private let queue: KeychainQueue
    private let gate: ConsentGatedTranscriber

    init(consent: CloudConsent, keys: any APIKeyStore, queue: KeychainQueue, gate: ConsentGatedTranscriber) {
        self.consent = consent
        self.keys = keys
        self.queue = queue
        self.gate = gate
    }

    /// Looks the key up (attributes only, never the secret) and publishes what it found.
    public func refreshKeyStatus() {
        queue.run({ [keys] in Self.status(of: keys) }) { [weak self] status in self?.publish(status) }
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

    /// `completion` gets the keychain failure, if any, once the status was refreshed.
    public func saveKey(_ key: OpenAIAPIKey, completion: @escaping @Sendable @MainActor (KeychainError?) -> Void) {
        change({ try $0.save(key) }, completion: completion)
    }

    /// Revokes authorization immediately, even if the subsequent Keychain deletion fails.
    public func removeKey(completion: @escaping @Sendable @MainActor (KeychainError?) -> Void) {
        consent.revoke()
        gate.refuseAll(.missingCredential)
        change({ try $0.delete() }, completion: completion)
        onChange?()
    }

    private func change(
        _ operation: @escaping @Sendable (any APIKeyStore) throws -> Void,
        completion: @escaping @Sendable @MainActor (KeychainError?) -> Void
    ) {
        queue.run({ [keys] in
            let failure: KeychainError?
            do {
                try operation(keys)
                failure = nil
            } catch {
                failure = KeychainError(error)
            }
            return KeyChange(failure: failure, status: Self.status(of: keys))
        }) { [weak self] change in
            self?.publish(change.status)
            completion(change.failure)
        }
    }

    private nonisolated static func status(of keys: any APIKeyStore) -> APIKeyStatus {
        APIKeyStatus(lookup: Result { try keys.contains() })
    }

    private func publish(_ status: APIKeyStatus) {
        keyStatus = status
        onChange?()
    }
}

private struct KeyChange: Sendable {
    let failure: KeychainError?
    let status: APIKeyStatus
}
