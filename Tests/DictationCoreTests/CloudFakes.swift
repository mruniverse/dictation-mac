@testable import DictationCore
import Foundation
import os
import Security
import XCTest

/// In-memory consent record; never touches the user's defaults.
final class MemoryConsentStorage: ConsentStorage {
    private(set) var values: [String: String] = [:]

    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

/// In-memory key store that records every call, the thread it ran on, and fails on demand.
final class FakeKeyStore: APIKeyStore {
    enum Operation: Hashable, Sendable { case read, contains, save, delete }

    private struct State {
        var key: OpenAIAPIKey?
        var calls: [Operation] = []
        var callsOnMainThread = 0
        var failures: [Operation: OSStatus] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ key: OpenAIAPIKey? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(key: key))
    }

    var calls: [Operation] { state.withLock { $0.calls } }
    var reads: Int { calls.filter { $0 == .read }.count }
    var probes: Int { calls.filter { $0 == .contains }.count }
    var callsOnMainThread: Int { state.withLock { $0.callsOnMainThread } }
    /// The stored key, without counting as a call.
    var storedKey: OpenAIAPIKey? { state.withLock { $0.key } }

    /// Every later call of `operations` throws `KeychainError(status:)`.
    func fail(_ operations: Operation..., status: OSStatus) {
        state.withLock { state in operations.forEach { state.failures[$0] = status } }
    }

    func read() throws -> OpenAIAPIKey? { try record(.read) { $0.key } }
    func contains() throws -> Bool { try record(.contains) { $0.key != nil } }
    func save(_ key: OpenAIAPIKey) throws { try record(.save) { $0.key = key } }
    func delete() throws { try record(.delete) { $0.key = nil } }

    private func record<T: Sendable>(_ operation: Operation, _ body: @Sendable (inout State) -> T) throws -> T {
        let onMain = Thread.isMainThread
        let outcome: Result<T, KeychainError> = state.withLock { state in
            state.calls.append(operation)
            if onMain { state.callsOnMainThread += 1 }
            if let status = state.failures[operation] { return .failure(KeychainError(status: status)) }
            return .success(body(&state))
        }
        return try outcome.get()
    }
}

/// Keychain queue under test control, used from the main thread: work runs at once, or waits for
/// `drain()` while `holds` is set; always in submission order.
final class ManualKeychainQueue: KeychainQueue, @unchecked Sendable {
    var holds = false
    private var pending: [@MainActor () -> Void] = []

    var pendingCount: Int { pending.count }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then deliver: @escaping @Sendable @MainActor (T) -> Void) {
        guard Thread.isMainThread else { return XCTFail("manual keychain queue used off the main thread") }
        MainActor.assumeIsolated {
            if holds { pending.append { deliver(work()) } } else { deliver(work()) }
        }
    }

    /// Runs everything submitted so far, and anything that submits, in order.
    @MainActor func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

/// Records first-send questions; answers only when the test says so.
@MainActor
final class FakeConfirmer {
    private(set) var asked: [TimeInterval] = []
    private(set) var withdrawn: [Int] = []
    /// Answers inside the question, before its handle is returned.
    var immediateAnswer: Bool?
    private var replies: [@Sendable @MainActor (Bool) -> Void] = []

    var confirmation: ConsentGatedTranscriber.FirstSendConfirmation {
        { [self] duration, reply in
            let index = asked.count
            asked.append(duration)
            replies.append(reply)
            if let immediateAnswer { reply(immediateAnswer) }
            return TranscriptionCancellation { self.withdrawn.append(index) }
        }
    }

    func answer(_ accepted: Bool, question index: Int = 0) {
        guard replies.indices.contains(index) else { return XCTFail("no first-send question \(index)") }
        replies[index](accepted)
    }
}

/// Keychain double with `SecItem` semantics for one generic-password class; records every query.
final class FakeKeychain: @unchecked Sendable {
    struct Call {
        let operation: String
        let query: [String: Any]
    }

    private let mutex = NSLock()
    private var items: [[String: Any]] = []
    private var log: [Call] = []
    /// Status returned by every call instead of the normal behaviour.
    var forcedStatus: OSStatus?

    var calls: [Call] { locked { log } }
    var storedItems: [[String: Any]] { locked { items } }

    func store(_ attributes: [String: Any]) { locked { items.append(attributes) } }

    private func locked<T>(_ body: () -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return body()
    }

    var functions: SecItemFunctions {
        SecItemFunctions(
            copy: { [self] query in
                locked {
                    log.append(Call(operation: "copy", query: query))
                    if let forcedStatus { return (forcedStatus, nil) }
                    guard let item = items.first(where: { Self.matches($0, query) }) else { return (errSecItemNotFound, nil) }
                    let wantsData = (query[kSecReturnData as String] as? Bool) == true
                    return (errSecSuccess, wantsData ? item[kSecValueData as String] as AnyObject : nil)
                }
            },
            add: { [self] attributes in
                locked {
                    log.append(Call(operation: "add", query: attributes))
                    if let forcedStatus { return forcedStatus }
                    guard !items.contains(where: { Self.matches($0, attributes) }) else { return errSecDuplicateItem }
                    items.append(attributes)
                    return errSecSuccess
                }
            },
            update: { [self] query, changes in
                locked {
                    log.append(Call(operation: "update", query: query.merging(changes) { $1 }))
                    if let forcedStatus { return forcedStatus }
                    guard let index = items.firstIndex(where: { Self.matches($0, query) }) else { return errSecItemNotFound }
                    items[index].merge(changes) { $1 }
                    return errSecSuccess
                }
            },
            delete: { [self] query in
                locked {
                    log.append(Call(operation: "delete", query: query))
                    if let forcedStatus { return forcedStatus }
                    let before = items.count
                    items.removeAll { Self.matches($0, query) }
                    return items.count < before ? errSecSuccess : errSecItemNotFound
                }
            }
        )
    }

    private static func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        [kSecClass, kSecAttrService, kSecAttrAccount].allSatisfy { attribute in
            let key = attribute as String
            return (item[key] as? String) == (query[key] as? String)
        }
    }
}
