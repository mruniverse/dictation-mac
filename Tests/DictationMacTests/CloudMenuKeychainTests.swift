import AppKit
import DictationCore
@testable import DictationMac
import XCTest

/// The app delegate's cloud menu over a counting key store: opening the menu never touches the
/// Keychain, and only the explicit load reads it, once. The app is not launched: no status item,
/// window, microphone, network or real Keychain.
@MainActor
final class CloudMenuKeychainTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func testOpeningTheMenuNeverTouchesTheKeychainAndOnlyTheExplicitLoadReadsIt() async throws {
        let store = CountingKeyStore()
        let delegate = AppDelegate()
        delegate.keyStore = store

        delegate.menuWillOpen(NSMenu())
        delegate.menuWillOpen(NSMenu())
        _ = delegate.perform(NSSelectorFromString("loadAPIKey"))
        // The keychain queue is serial: anything the menu had queued would run before the load.
        try await waitUntil { store.operations.contains("read") }
        delegate.menuWillOpen(NSMenu())
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.operations, ["read"])
        XCTAssertEqual(store.callsOnMainThread, 0)
    }

    func testKeyStatusTitlesTellNotLoadedLoadedMissingRefusedAndWaitingApart() {
        XCTAssertEqual(AppDelegate.keyStatusTitle(.notLoaded, waiting: false), "Chave de API: não carregada nesta execução")
        XCTAssertEqual(AppDelegate.keyStatusTitle(.loaded, waiting: false), "Chave de API: carregada nesta execução")
        XCTAssertEqual(AppDelegate.keyStatusTitle(.missing, waiting: false), "Chave de API: nenhuma salva no Keychain")
        XCTAssertEqual(
            AppDelegate.keyStatusTitle(.unavailable(KeychainError(status: -25308)), waiting: false),
            "Chave de API: Keychain não liberou (código -25308)"
        )
        XCTAssertEqual(AppDelegate.keyStatusTitle(.loaded, waiting: true), "Chave de API: aguardando o Keychain…")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }
}

/// Records every call and the thread it ran on; holds no real key and never touches the Keychain.
private final class CountingKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var onMain = 0

    var operations: [String] { locked { log } }
    var callsOnMainThread: Int { locked { onMain } }

    func read() throws -> OpenAIAPIKey? {
        record("read")
        return OpenAIAPIKey("placeholder-key-for-tests")
    }

    func save(_ key: OpenAIAPIKey) throws { record("save") }
    func delete() throws { record("delete") }

    private func record(_ operation: String) {
        let main = Thread.isMainThread
        locked {
            log.append(operation)
            if main { onMain += 1 }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
