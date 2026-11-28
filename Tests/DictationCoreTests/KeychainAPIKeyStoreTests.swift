@testable import DictationCore
import Security
import XCTest

/// Keychain store over a recorded `SecItem` double; the user's keychain is never touched.
final class KeychainAPIKeyStoreTests: XCTestCase {
    private let service = "test.service"
    private let account = "default"

    private func makeStore(_ keychain: FakeKeychain) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: service, account: account, keychain: keychain.functions)
    }

    private func string(_ query: [String: Any], _ attribute: CFString) -> String? {
        query[attribute as String] as? String
    }

    func testDefaultServiceIsTheAppsOwnItem() {
        XCTAssertEqual(KeychainAPIKeyStore.defaultService, "io.github.mruniverse.DictationMac.openai-api-key")
    }

    func testSaveCreatesOneLocalGenericPasswordAndReadReturnsIt() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        try store.save(placeholderKey)

        XCTAssertEqual(try store.read()?.value, "placeholder-key-for-tests")
        let added = try XCTUnwrap(keychain.calls.first { $0.operation == "add" }?.query)
        XCTAssertEqual(string(added, kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(string(added, kSecAttrService), service)
        XCTAssertEqual(string(added, kSecAttrAccount), account)
        XCTAssertEqual(added[kSecValueData as String] as? Data, Data("placeholder-key-for-tests".utf8))
        XCTAssertNil(added[kSecAttrSynchronizable as String], "never synchronized through iCloud Keychain")
        XCTAssertNil(added[kSecUseDataProtectionKeychain as String])
        let label = try XCTUnwrap(string(added, kSecAttrLabel))
        XCTAssertFalse(label.contains("placeholder-key-for-tests"))
    }

    func testSavingAgainReplacesTheKeyInsteadOfAddingAnItem() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        try store.save(placeholderKey)
        try store.save(OpenAIAPIKey("second-placeholder-key")!)

        XCTAssertEqual(keychain.storedItems.count, 1)
        XCTAssertEqual(try store.read()?.value, "second-placeholder-key")
    }

    func testNoQueryEverAsksForSynchronizableItems() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)

        try store.save(placeholderKey)
        _ = try store.read()
        try store.delete()

        XCTAssertFalse(keychain.calls.isEmpty)
        for call in keychain.calls {
            XCTAssertNil(call.query[kSecAttrSynchronizable as String], call.operation)
        }
    }

    func testReadAsksForTheDataOfTheAppsOwnItemOnly() throws {
        let keychain = FakeKeychain()
        _ = try makeStore(keychain).read()

        XCTAssertEqual(keychain.calls.count, 1)
        let query = try XCTUnwrap(keychain.calls.first?.query)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(string(query, kSecMatchLimit), kSecMatchLimitOne as String)
        XCTAssertEqual(string(query, kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(string(query, kSecAttrService), service)
        XCTAssertEqual(string(query, kSecAttrAccount), account)
        XCTAssertNil(query[kSecReturnAttributes as String])
        XCTAssertNil(query[kSecReturnRef as String])
    }

    func testMissingKeyReadsAsNilAndDeleteIsIdempotent() throws {
        let store = makeStore(FakeKeychain())

        XCTAssertNil(try store.read())
        try store.delete()
        try store.save(placeholderKey)
        try store.delete()
        try store.delete()

        XCTAssertNil(try store.read())
    }

    func testCorruptedItemIsAnErrorNotAKey() throws {
        let keychain = FakeKeychain()
        keychain.store([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("two words\n".utf8),
        ])

        XCTAssertThrowsError(try makeStore(keychain).read()) {
            XCTAssertEqual($0 as? KeychainError, KeychainError(status: errSecDecode))
        }
    }

    func testKeychainFailuresCarryOnlyTheStatus() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(placeholderKey)
        keychain.forcedStatus = errSecInteractionNotAllowed

        for operation in [{ _ = try store.read() }, { try store.save(placeholderKey) }, { try store.delete() }] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecInteractionNotAllowed))
                let rendered = [String(describing: error), String(reflecting: error), error.localizedDescription].joined()
                XCTAssertFalse(rendered.contains("placeholder-key-for-tests"))
            }
        }
    }
}

/// Keys and transcripts must never reach a log: the sources of both targets contain no logging,
/// console or standard-stream call at all.
final class SourceHygieneTests: XCTestCase {
    /// Any way Swift code here could emit text to a log, the console or a standard stream.
    static let logging = try! NSRegularExpression(pattern: [
        #"\b(?:print|debugPrint|dump)\s*[(),]"#,
        #"\b(?:NSLogv?|os_log\w*|os_signpost\w*|Logger|OSLog|puts|fputs|v?f?printf|syslog|CFShow)\s*\("#,
        #"\bimport\s+(?:os|OSLog)\b"#,
        #"\bFileHandle\.standard(?:Error|Output)\b"#,
    ].joined(separator: "|"))

    func testScannerFlagsEveryLoggingForm() {
        let flagged = [
            "print(key)", "Swift.print(text)", "debugPrint(error)", "dump(request)",
            "NSLog(\"%@\", key)", "NSLogv(format, args)", "os_log(.error, \"%{public}@\", text)",
            "os_log_error(log, \"x\")", "os_signpost(.begin, log: log, name: \"x\")",
            "let log = Logger(subsystem: \"s\", category: \"c\")", "OSLog(subsystem: \"s\", category: \"c\")",
            "import os", "import OSLog", "import os.log",
            "fputs(text, stderr)", "fprintf(stderr, \"%s\", text)", "printf(\"%s\", text)", "puts(text)",
            "vprintf(format, args)", "syslog(LOG_ERR, \"%s\", text)", "FileHandle.standardError.write(data)",
            "FileHandle.standardOutput.write(data)", "CFShow(value)", "lines.forEach(print)",
        ]
        for line in flagged {
            XCTAssertEqual(Self.hits(in: line), 1, "not flagged: \(line)")
        }
        for line in ["let blueprint = 1", "fingerprint(of: data)", "// printed menu", "os.allocated", "import OSLogStore"] {
            XCTAssertEqual(Self.hits(in: line), 0, "false positive: \(line)")
        }
    }

    func testSourcesNeverLog() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let names = Set(files.map(\.lastPathComponent))
        for expected in ["APIKeyStore.swift", "OpenAITranscriber.swift", "CloudDialogs.swift", "DictationMacApp.swift"] {
            XCTAssertTrue(names.contains(expected), "scan misses \(expected)")
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(Self.hits(in: text), 0, "logging call in \(file.lastPathComponent)")
        }
    }

    private static func hits(in text: String) -> Int {
        logging.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
