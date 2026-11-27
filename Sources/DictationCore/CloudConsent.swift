import Foundation

/// Non-secret key-value storage for the consent record: `UserDefaults` in the app, memory in tests.
public protocol ConsentStorage: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ConsentStorage {}

public enum CloudConsentState: Equatable, Sendable {
    /// Nothing may be sent.
    case notGranted
    /// The user authorized sending; the next clip still needs an explicit confirmation.
    case awaitingFirstSend
    /// Authorized, and the first send was confirmed.
    case active
}

/// The user's decision to send audio to one cloud destination. Kept apart from the API key: saving
/// a key never grants it and revoking it never deletes the key. The record names its destination,
/// so a decision stored for another endpoint or model reads as not granted. Holds no secret.
@MainActor
public final class CloudConsent {
    static let storageKey = "cloudTranscription.consent"

    private let storage: ConsentStorage
    private let destination: String

    public init(storage: ConsentStorage, destination: String = OpenAITranscriber.destination) {
        self.storage = storage
        self.destination = destination
    }

    public var state: CloudConsentState {
        switch storage.string(forKey: Self.storageKey) {
        case "granted " + destination: .awaitingFirstSend
        case "confirmed " + destination: .active
        default: .notGranted
        }
    }

    /// Explicit user action only. Keeps an earlier first-send confirmation for the same destination.
    public func grant() {
        guard state == .notGranted else { return }
        storage.set("granted " + destination, forKey: Self.storageKey)
    }

    /// Called once the user confirmed the first clip.
    func confirmFirstSend() {
        guard state == .awaitingFirstSend else { return }
        storage.set("confirmed " + destination, forKey: Self.storageKey)
    }

    /// Withdraws consent and the first-send confirmation; granting again asks for it again.
    public func revoke() {
        storage.removeObject(forKey: Self.storageKey)
    }
}
