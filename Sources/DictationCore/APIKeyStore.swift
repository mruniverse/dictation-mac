import Foundation
import Security

/// Where the user's API key lives. Implementations never log, print or describe the key.
public protocol APIKeyStore: Sendable {
    /// The stored key, or nil when there is none. May show the system keychain authorization dialog.
    func read() throws -> OpenAIAPIKey?
    /// Whether a key is stored, without reading the secret.
    func contains() throws -> Bool
    /// Replaces any stored key.
    func save(_ key: OpenAIAPIKey) throws
    /// Idempotent.
    func delete() throws
}

/// Keychain failure reduced to its status code; never carries the item, its data or the query.
public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String { "KeychainError(\(status))" }

    /// Any store failure as a status code; never carries the failure's text.
    init(_ error: Error) {
        self = error as? KeychainError ?? KeychainError(status: errSecInternalError)
    }
}

/// What the key lookup found. A keychain failure is its own case: it never reads as a missing key.
public enum APIKeyStatus: Equatable, Sendable {
    /// Not looked up yet.
    case unknown
    case stored
    case missing
    /// The keychain refused the lookup (locked, access denied, damaged item): a key may exist.
    case unavailable(KeychainError)

    init(lookup: Result<Bool, Error>) {
        self = switch lookup {
        case .success(true): .stored
        case .success(false): .missing
        case let .failure(error): .unavailable(KeychainError(error))
        }
    }
}

/// One generic-password item in the user's login keychain. That is the file-based keychain: the
/// data-protection keychain needs entitlements an ad-hoc build does not have, and `kSecAttrAccessible`
/// is not supported there, so it is not set. The item is not synchronizable (never leaves this Mac
/// through iCloud Keychain) and its default access list trusts only the app that created it.
public struct KeychainAPIKeyStore: APIKeyStore {
    public static let defaultService = "io.github.mruniverse.DictationMac.openai-api-key"
    /// Shown in Keychain Access; describes the item, never contains the key.
    static let label = "Dictation Mac — chave de API da OpenAI"

    let service: String
    let account: String
    let keychain: SecItemFunctions

    public init(service: String = Self.defaultService, account: String = "default") {
        self.init(service: service, account: account, keychain: .system)
    }

    init(service: String, account: String, keychain: SecItemFunctions) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> OpenAIAPIKey? {
        var query = item
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = keychain.copy(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8),
                  let key = OpenAIAPIKey(text)
            else { throw KeychainError(status: errSecDecode) }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func contains() throws -> Bool {
        var query = item
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // No kSecReturnData: the secret is never decrypted, so no authorization dialog is needed.
        switch keychain.copy(query).status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case let status: throw KeychainError(status: status)
        }
    }

    public func save(_ key: OpenAIAPIKey) throws {
        let secret = Data(key.value.utf8)
        let updated = keychain.update(item, [kSecValueData as String: secret])
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = item
            attributes[kSecAttrLabel as String] = Self.label
            attributes[kSecValueData as String] = secret
            let added = keychain.add(attributes)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: updated)
        }
    }

    public func delete() throws {
        let status = keychain.delete(item)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The four `SecItem` calls, injectable so tests never touch the user's keychain.
struct SecItemFunctions: Sendable {
    var copy: @Sendable (_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    var update: @Sendable (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    var delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let system = SecItemFunctions(
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}
