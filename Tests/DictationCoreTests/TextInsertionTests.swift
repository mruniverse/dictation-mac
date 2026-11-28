import DictationCore
import Foundation
import XCTest

@MainActor
private final class RecordingTextInsertionTarget: TextInsertionTarget {
    var inserts: [(text: String, token: UUID)] = []
    var releases: [UUID] = []
    var nextResult: TextInsertionResult = .inserted
    var onInsert: (() -> Void)?

    func insert(_ text: String, into lock: TextInsertionLock) -> TextInsertionResult {
        inserts.append((text, lock.token))
        onInsert?()
        return nextResult
    }

    func release(_ lock: TextInsertionLock) {
        releases.append(lock.token)
    }
}

@MainActor
final class TextInsertionTests: XCTestCase {
    private var target: RecordingTextInsertionTarget!
    private var coordinator: TextInsertionCoordinator!

    override func setUp() async throws {
        target = RecordingTextInsertionTarget()
        coordinator = TextInsertionCoordinator(target: target)
    }

    private func transcript(_ text: String) -> Outcome {
        .transcribed(text, duration: 1)
    }

    private func sanitized(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        target.inserts.removeAll()
        coordinator.setEnabled(true)
        let session = UUID()
        coordinator.bind(TextInsertionLock(token: UUID()), to: session)
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript(text))
        if result == nil {
            XCTAssertTrue(target.inserts.isEmpty, "TI-RED sanitizador: nil não deve chamar insert", file: file, line: line)
            return nil
        }
        XCTAssertEqual(target.inserts.count, 1, "TI-RED sanitizador: esperava uma inserção", file: file, line: line)
        return target.inserts.first?.text
    }

    // MARK: Enablement

    func testDisabledByDefault() {
        XCTAssertFalse(coordinator.isEnabled, "TI-RED: isEnabled deve iniciar falso")
    }

    func testBindWhileDisabledReleasesNewLockImmediately() {
        let lock = TextInsertionLock(token: UUID())
        let session = UUID()
        coordinator.bind(lock, to: session)
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: bind desabilitado deve liberar o lock novo")
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("oi"))
        XCTAssertNil(result, "TI-RED: sem lock vinculado não há inserção")
        XCTAssertTrue(target.inserts.isEmpty, "TI-RED: desabilitado não deve inserir")
    }

    func testDisablingReleasesCurrentLockAndLaterSessionIsNotAffected() {
        coordinator.setEnabled(true)
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: UUID())
        coordinator.setEnabled(false)
        XCTAssertFalse(coordinator.isEnabled, "TI-RED: setEnabled(false) deve desabilitar")
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: desabilitar deve liberar o lock atual")

        coordinator.setEnabled(true)
        let session = UUID()
        coordinator.bind(TextInsertionLock(token: UUID()), to: session)
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("depois"))
        XCTAssertEqual(result, .inserted, "TI-RED: sessão futura após reabilitar deve inserir")
    }

    // MARK: Binding and replacement

    func testReplacingBindReleasesPreviousLockOnce() {
        coordinator.setEnabled(true)
        let first = TextInsertionLock(token: UUID())
        let second = TextInsertionLock(token: UUID())
        coordinator.bind(first, to: UUID())
        coordinator.bind(second, to: UUID())
        XCTAssertEqual(target.releases, [first.token], "TI-RED: substituir deve liberar exatamente o anterior")
    }

    func testInvalidateReleasesCurrentLockWithoutTouchingFutureSession() {
        coordinator.setEnabled(true)
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: UUID())
        coordinator.invalidate()
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: invalidate deve liberar o lock atual")

        let session = UUID()
        coordinator.bind(TextInsertionLock(token: UUID()), to: session)
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: bind após invalidate não deve liberar a sessão futura")
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("ok"))
        XCTAssertEqual(result, .inserted, "TI-RED: sessão futura após invalidate deve inserir")
    }

    // MARK: Finish eligibility and consumption

    func testFinishInsertsOnlyForEnabledPushToTalkTranscript() {
        coordinator.setEnabled(true)
        let session = UUID()
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: session)
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("olá"))
        XCTAssertEqual(result, .inserted, "TI-RED: finish elegível deve retornar o resultado do alvo")
        XCTAssertEqual(target.inserts.map(\.text), ["olá"], "TI-RED: deve inserir o texto sanitizado")
        XCTAssertEqual(target.inserts.first?.token, lock.token, "TI-RED: deve inserir com o lock vinculado")
    }

    func testManualOriginIsIneligibleAndStillConsumesAndReleasesLock() {
        coordinator.setEnabled(true)
        let session = UUID()
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: session)
        let result = coordinator.finish(session: session, origin: .manual, outcome: transcript("manual"))
        XCTAssertNil(result, "TI-RED: origem manual não é elegível")
        XCTAssertTrue(target.inserts.isEmpty, "TI-RED: origem manual não deve inserir")
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: sessão encerrada deve liberar o lock")
        XCTAssertNil(coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("de novo")),
                     "TI-RED: lock já consumido não pode ser reutilizado")
    }

    func testDiscardedOutcomeIsNotInsertedButConsumesLock() {
        coordinator.setEnabled(true)
        let session = UUID()
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: session)
        let result = coordinator.finish(session: session, origin: .pushToTalk,
                                        outcome: .discarded(.pushToTalkExpired, duration: 2))
        XCTAssertNil(result, "TI-RED: descartado não é elegível")
        XCTAssertTrue(target.inserts.isEmpty, "TI-RED: descartado não deve inserir")
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: descartado ainda deve liberar o lock")
    }

    func testFinishConsumesLockBeforeCallbackAndReleasesExactlyOnce() {
        coordinator.setEnabled(true)
        let session = UUID()
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: session)
        var reentrant: TextInsertionResult??
        target.onInsert = { [unowned self] in
            if reentrant == nil {
                reentrant = .some(nil)
                reentrant = .some(self.coordinator.finish(session: session, origin: .pushToTalk,
                                                          outcome: self.transcript("reentrante")))
            }
        }
        let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("primeiro"))
        XCTAssertEqual(result, .inserted, "TI-RED: primeira chamada deve inserir")
        XCTAssertEqual(reentrant, .some(nil), "TI-RED: reentrância com mesmo ID deve retornar nil (já consumido)")
        XCTAssertEqual(target.inserts.map(\.text), ["primeiro"], "TI-RED: reentrância não pode gerar segunda inserção")
        XCTAssertEqual(target.releases, [lock.token], "TI-RED: lock deve ser liberado exatamente uma vez")
    }

    func testStaleSessionDoesNotConsumeCurrentLock() {
        coordinator.setEnabled(true)
        let current = UUID()
        let lock = TextInsertionLock(token: UUID())
        coordinator.bind(lock, to: current)
        let stale = coordinator.finish(session: UUID(), origin: .pushToTalk, outcome: transcript("antigo"))
        XCTAssertNil(stale, "TI-RED: ID diferente não deve retornar resultado")
        XCTAssertTrue(target.inserts.isEmpty, "TI-RED: ID diferente não deve inserir")
        XCTAssertTrue(target.releases.isEmpty, "TI-RED: ID diferente não deve liberar o lock atual")
        let result = coordinator.finish(session: current, origin: .pushToTalk, outcome: transcript("atual"))
        XCTAssertEqual(result, .inserted, "TI-RED: sessão atual ainda deve inserir após evento stale")
    }

    func testFailedAndUnconfirmedResultsAreReturnedWithoutRetry() {
        for outcome: TextInsertionResult in [.notInserted, .unconfirmed] {
            target.nextResult = outcome
            coordinator.setEnabled(true)
            let session = UUID()
            coordinator.bind(TextInsertionLock(token: UUID()), to: session)
            let result = coordinator.finish(session: session, origin: .pushToTalk, outcome: transcript("texto"))
            XCTAssertEqual(result, outcome, "TI-RED: resultado \(outcome) deve ser repassado")
        }
        XCTAssertEqual(target.inserts.count, 2, "TI-RED: falha ou indeterminado não pode gerar nova tentativa")
    }

    // MARK: Sanitization

    func testSanitizerKeepsPlainUnicodeAndInternalSpaces() {
        let text = "São Paulo  café 👍🏽 👨‍👩‍👧 fim"
        XCTAssertEqual(sanitized(text), text, "TI-RED sanitizador: acentos, emoji, ZWJ e espaços internos devem ser preservados")
    }

    func testLineBreaksAndTabsBecomeSingleSpaces() {
        XCTAssertEqual(sanitized("a\r\nb"), "a b", "TI-RED sanitizador: CRLF deve virar um espaço")
        XCTAssertEqual(sanitized("a\rb"), "a b", "TI-RED sanitizador: CR deve virar espaço")
        XCTAssertEqual(sanitized("a\nb"), "a b", "TI-RED sanitizador: LF deve virar espaço")
        XCTAssertEqual(sanitized("a\tb"), "a b", "TI-RED sanitizador: tab deve virar espaço")
        XCTAssertEqual(sanitized("a\u{2028}b\u{2029}c"), "a b c", "TI-RED sanitizador: U+2028/2029 devem virar espaço")
        XCTAssertEqual(sanitized("a\r\n\r\nb"), "a  b", "TI-RED sanitizador: cada CRLF vira um espaço")
    }

    func testControlDELAndBidiCharactersAreRemoved() {
        XCTAssertEqual(sanitized("a\u{0000}\u{0007}\u{001B}b"), "ab", "TI-RED sanitizador: C0 deve sair")
        XCTAssertEqual(sanitized("a\u{0085}\u{009F}b"), "ab", "TI-RED sanitizador: C1 deve sair")
        XCTAssertEqual(sanitized("a\u{007F}b"), "ab", "TI-RED sanitizador: DEL deve sair")
        XCTAssertEqual(sanitized("a\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}b"), "ab",
                       "TI-RED sanitizador: embeddings bidi U+202A–202E devem sair")
        XCTAssertEqual(sanitized("a\u{2066}\u{2067}\u{2068}\u{2069}b"), "ab",
                       "TI-RED sanitizador: isolates bidi U+2066–2069 devem sair")
    }

    func testEmptyAfterTrimIsNotInserted() {
        XCTAssertNil(sanitized("   \n\t  "), "TI-RED sanitizador: vazio após trim não insere")
        XCTAssertNil(sanitized("\u{202E}\u{0007}"), "TI-RED sanitizador: só controles não insere")
    }

    func testLengthBoundIsUTF16AndAppliesToInput() {
        let atLimit = String(repeating: "a", count: 10_000)
        XCTAssertEqual(sanitized(atLimit), atLimit, "TI-RED sanitizador: 10_000 UTF-16 deve ser aceito")
        XCTAssertNil(sanitized(atLimit + "a"), "TI-RED sanitizador: entrada acima de 10_000 UTF-16 deve ser recusada")
        let emojiOverLimit = String(repeating: "😀", count: 5_001)
        XCTAssertNil(sanitized(emojiOverLimit), "TI-RED sanitizador: limite conta UTF-16, não caracteres")
    }

    func testTrimmedOutputIsInsertedWithoutEdgeWhitespace() {
        XCTAssertEqual(sanitized("  oi\n"), "oi", "TI-RED sanitizador: bordas de espaço devem ser removidas")
    }
}
