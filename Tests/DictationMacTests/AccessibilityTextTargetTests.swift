import Carbon
import DictationCore
@testable import DictationMac
import XCTest

// Nothing here reaches the real Accessibility API, TCC, the window server, another process, the
// microphone, the network or the clipboard: elements are plain objects and every text is synthetic.

private let textEditPID: pid_t = 4101
private let terminalPID: pid_t = 4202
private let ownPID: pid_t = 4303
private let launched = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
final class FakeAXElement {
    var pid: pid_t?
    var role: AccessibilityRead<String>
    var subrole: AccessibilityRead<String> = .absent
    var focusedWindow: FakeAXElement?
    var focusedUIElement: FakeAXElement?
    var window: FakeAXElement?
    var selectedTextSettable: Bool? = true
    var selection: AccessibilityTextRange?

    init(pid: pid_t?, role: AccessibilityRead<String>) {
        self.pid = pid
        self.role = role
    }
}

/// Records every call by name only; writes behave like NSTextView (caret after the text, in UTF-16).
@MainActor
final class FakeAccessibility: AccessibilityBackend {
    var trusted = true
    private(set) var trustPrompts = 0
    var secureInput = false
    var frontmost: pid_t?
    var focusedApp: FakeAXElement?
    var identities: [pid_t: AccessibilityProcess] = [:]
    var writeStatus = AccessibilityWriteStatus.success
    /// Caret reported after a successful write; default: right after the written text.
    var caretAfterWrite: ((_ before: AccessibilityTextRange, _ text: String) -> AccessibilityTextRange?)?
    /// Answer of a written-range read; default: the written text when the range is exactly the written one.
    var writtenRangeText: ((AccessibilityTextRange) -> String?)?
    var onSelectionRead: (() -> Void)?
    private(set) var log: [String] = []
    private(set) var writeAttempts: [String] = []
    private var lastWrite: (range: AccessibilityTextRange, text: String)?

    private func node(_ handle: AccessibilityElement) -> FakeAXElement? { handle.object as? FakeAXElement }

    func isTrusted() -> Bool {
        log.append("trusted")
        return trusted
    }

    func requestTrust() {
        log.append("requestTrust")
        trustPrompts += 1
    }

    func isSecureInputEnabled() -> Bool {
        log.append("secureInput")
        return secureInput
    }

    func frontmostProcess() -> pid_t? {
        log.append("frontmost")
        return frontmost
    }

    func focusedApplication() -> AccessibilityElement? {
        log.append("focusedApplication")
        return focusedApp.map { AccessibilityElement(object: $0) }
    }

    func process(_ pid: pid_t) -> AccessibilityProcess? {
        log.append("process")
        return identities[pid]
    }

    func processIdentifier(of element: AccessibilityElement) -> pid_t? {
        log.append("pid")
        return node(element)?.pid
    }

    func element(_ attribute: AccessibilityElementAttribute, of element: AccessibilityElement) -> AccessibilityElement? {
        log.append("\(attribute)")
        let target: FakeAXElement? = switch attribute {
        case .focusedWindow: node(element)?.focusedWindow
        case .focusedUIElement: node(element)?.focusedUIElement
        case .window: node(element)?.window
        }
        return target.map { AccessibilityElement(object: $0) }
    }

    func string(_ attribute: AccessibilityStringAttribute, of element: AccessibilityElement) -> AccessibilityRead<String> {
        log.append("\(attribute)")
        guard let node = node(element) else { return .failed }
        return switch attribute {
        case .role: node.role
        case .subrole: node.subrole
        }
    }

    func isSelectedTextSettable(_ element: AccessibilityElement) -> Bool? {
        log.append("settable")
        return node(element)?.selectedTextSettable
    }

    func selectedRange(of element: AccessibilityElement) -> AccessibilityTextRange? {
        log.append("selectedRange")
        onSelectionRead?()
        return node(element)?.selection
    }

    func setSelectedText(_ text: String, of element: AccessibilityElement) -> AccessibilityWriteStatus {
        log.append("write")
        writeAttempts.append(text)
        guard writeStatus == .success, let field = node(element), let before = field.selection else { return writeStatus }
        let written = AccessibilityTextRange(location: before.location, length: text.utf16.count)
        lastWrite = (written, text)
        field.selection = caretAfterWrite.map { $0(before, text) }
            ?? AccessibilityTextRange(location: before.location + text.utf16.count, length: 0)
        return .success
    }

    func string(in range: AccessibilityTextRange, of element: AccessibilityElement) -> String? {
        log.append("stringForRange(\(range.location),\(range.length))")
        if let writtenRangeText { return writtenRangeText(range) }
        guard let lastWrite, lastWrite.range == range else { return nil }
        return lastWrite.text
    }

    func isSame(_ a: AccessibilityElement, _ b: AccessibilityElement) -> Bool {
        guard let a = node(a), let b = node(b) else { return false }
        return a === b
    }
}

/// A focused TextEdit document: standard window, writable text area, empty selection at `caret`.
@MainActor
private struct Desktop {
    let ax: FakeAccessibility
    let app: FakeAXElement
    let window: FakeAXElement
    let field: FakeAXElement

    init(_ ax: FakeAccessibility, caret: Int = 5) {
        self.ax = ax
        app = FakeAXElement(pid: textEditPID, role: .value("AXApplication"))
        window = FakeAXElement(pid: textEditPID, role: .value("AXWindow"))
        window.subrole = .value("AXStandardWindow")
        field = FakeAXElement(pid: textEditPID, role: .value("AXTextArea"))
        field.window = window
        field.selection = AccessibilityTextRange(location: caret, length: 0)
        app.focusedWindow = window
        app.focusedUIElement = field
        ax.focusedApp = app
        ax.frontmost = textEditPID
        ax.identities[textEditPID] = AccessibilityProcess(pid: textEditPID, bundleIdentifier: "com.apple.TextEdit", launchDate: launched)
        ax.identities[terminalPID] = AccessibilityProcess(pid: terminalPID, bundleIdentifier: "com.apple.Terminal", launchDate: launched)
    }

    /// Moves the focus to a Terminal window whose text area would otherwise qualify.
    func focusTerminal() {
        let terminal = FakeAXElement(pid: terminalPID, role: .value("AXApplication"))
        let window = FakeAXElement(pid: terminalPID, role: .value("AXWindow"))
        window.subrole = .value("AXStandardWindow")
        let area = FakeAXElement(pid: terminalPID, role: .value("AXTextArea"))
        area.window = window
        area.selection = AccessibilityTextRange(location: 0, length: 0)
        terminal.focusedWindow = window
        terminal.focusedUIElement = area
        ax.focusedApp = terminal
        ax.frontmost = terminalPID
    }
}

@MainActor
final class AccessibilityTextTargetTests: XCTestCase {
    private var ax: FakeAccessibility!
    private var desktop: Desktop!
    private var target: AccessibilityTextTarget!
    private let text = "Olá, café com açúcar 👍🏽"

    override func setUp() async throws {
        ax = FakeAccessibility()
        desktop = Desktop(ax)
        target = AccessibilityTextTarget(backend: ax)
    }

    private func lockOrFail(file: StaticString = #filePath, line: UInt = #line) throws -> TextInsertionLock {
        try XCTUnwrap(target.lock(), "AX-RED: TextEdit focado e válido deve gerar lock", file: file, line: line)
    }

    // MARK: Success

    func testInsertsExactlyOnceAtTheLockedCaretAndConfirmsByTheUTF16Caret() throws {
        let lock = try lockOrFail()
        XCTAssertEqual(target.lockedProcessIdentifier, textEditPID)

        let result = target.insert(text, into: lock)

        XCTAssertEqual(result, .inserted, "AX-RED: escrita confirmada deve retornar .inserted")
        XCTAssertEqual(ax.writeAttempts, [text], "AX-RED: uma única escrita, com o texto exato")
        XCTAssertEqual(desktop.field.selection, AccessibilityTextRange(location: 5 + text.utf16.count, length: 0))
        let contentReads = ax.log.filter { $0.hasPrefix("stringForRange") }
        XCTAssertEqual(contentReads, ["stringForRange(5,\(text.utf16.count))"], "AX-RED: só a faixa escrita é lida")
        XCTAssertNil(target.lockedProcessIdentifier, "AX-RED: o lock é consumido pela tentativa")
    }

    func testOnlyIdentityRoleAndSelectionAttributesAreEverRead() throws {
        let lock = try lockOrFail()
        _ = target.insert(text, into: lock)

        let allowed: Set<String> = [
            "trusted", "secureInput", "frontmost", "focusedApplication", "process", "pid", "focusedWindow",
            "focusedUIElement", "window", "role", "subrole", "settable", "selectedRange", "write",
        ]
        let unexpected = ax.log.filter { !allowed.contains($0) && !$0.hasPrefix("stringForRange(5,") }
        XCTAssertEqual(unexpected, [], "AX-RED: nenhuma leitura além de identidade, papel e seleção")
        XCTAssertEqual(ax.trustPrompts, 0, "AX-RED: inserir nunca abre o pedido de Acessibilidade")
    }

    func testWrittenRangeThatCannotBeReadStillConfirmsByTheCaret() throws {
        ax.writtenRangeText = { _ in nil }
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert(text, into: lock), .inserted, "AX-RED: AXStringForRange é dispensável")
    }

    // MARK: Lock lifecycle

    func testTheLockIsConsumedByTheFirstAttemptAndReleaseIsIdempotent() throws {
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert(text, into: lock), .inserted)
        XCTAssertEqual(target.insert(text, into: lock), .notInserted, "AX-RED: sem segunda tentativa com o mesmo lock")
        target.release(lock)
        target.release(lock)
        XCTAssertEqual(ax.writeAttempts.count, 1)

        let released = try lockOrFail()
        target.release(released)
        target.release(released)
        XCTAssertNil(target.lockedProcessIdentifier)
        XCTAssertEqual(target.insert(text, into: released), .notInserted, "AX-RED: lock liberado não escreve")
        XCTAssertEqual(ax.writeAttempts.count, 1)
    }

    /// A refused write leaves the caret where it was, so only consumption stops a second attempt.
    func testARefusedWriteConsumesTheLockEvenThoughTheTargetStillQualifies() throws {
        ax.writeStatus = .rejected
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert(text, into: lock), .notInserted)
        ax.writeStatus = .success
        XCTAssertEqual(target.insert(text, into: lock), .notInserted, "AX-RED: o destino é consumido antes da tentativa")
        XCTAssertEqual(ax.writeAttempts, [text], "AX-RED: nenhuma segunda escrita")
    }

    func testANewerLockSupersedesTheOlderOne() throws {
        let older = try lockOrFail()
        let newer = try lockOrFail()

        target.release(older)
        XCTAssertEqual(target.insert(text, into: older), .notInserted, "AX-RED: lock antigo não escreve")
        XCTAssertEqual(target.insert(text, into: newer), .inserted, "AX-RED: liberar o antigo não afeta o novo")
        XCTAssertEqual(ax.writeAttempts.count, 1)
    }

    func testEmptyTextIsNeverWritten() throws {
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert("", into: lock), .notInserted)
        XCTAssertEqual(ax.writeAttempts, [])
    }

    // MARK: Destination policy at the press

    func testOnlyTextEditIsAllowedAndOtherAppsAreNeverInspected() {
        desktop.focusTerminal()

        XCTAssertNil(target.lock(), "AX-RED: Terminal fica em prévia/cópia")
        for attribute in ["focusedWindow", "focusedUIElement", "role", "settable", "selectedRange", "write"] {
            XCTAssertFalse(ax.log.contains(attribute), "AX-RED: nada do Terminal é lido além da identidade: \(attribute)")
        }

        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.TextEdit.helper", "com.apple.textedit"] {
            ax.identities[terminalPID] = AccessibilityProcess(pid: terminalPID, bundleIdentifier: bundle, launchDate: launched)
            XCTAssertNil(target.lock(), "AX-RED: allowlist exclusiva do TextEdit: \(bundle)")
        }
        ax.identities[terminalPID] = AccessibilityProcess(pid: terminalPID, bundleIdentifier: nil, launchDate: launched)
        XCTAssertNil(target.lock(), "AX-RED: sem bundle identifier não há evidência")
        XCTAssertEqual(ax.writeAttempts, [])
    }

    func testPasswordFieldsAndOtherControlsAreRefused() {
        let cases: [(String, (Desktop) -> Void)] = [
            ("campo de senha", { $0.field.subrole = .value("AXSecureTextField") }),
            ("subrole ilegível", { $0.field.subrole = .failed }),
            ("campo de linha única", { $0.field.role = .value("AXTextField") }),
            ("papel ilegível", { $0.field.role = .failed }),
            ("não gravável", { $0.field.selectedTextSettable = false }),
            ("gravabilidade desconhecida", { $0.field.selectedTextSettable = nil }),
            ("seleção não vazia", { $0.field.selection = AccessibilityTextRange(location: 5, length: 3) }),
            ("seleção ilegível", { $0.field.selection = nil }),
            ("seleção negativa", { $0.field.selection = AccessibilityTextRange(location: -1, length: 0) }),
            ("janela de diálogo", { $0.window.subrole = .value("AXDialog") }),
            ("janela sem subrole", { $0.window.subrole = .absent }),
            ("papel da janela", { $0.window.role = .value("AXSheet") }),
            ("campo de outra janela", { $0.field.window = FakeAXElement(pid: textEditPID, role: .value("AXWindow")) }),
            ("campo sem janela", { $0.field.window = nil }),
            ("sem janela focada", { $0.app.focusedWindow = nil }),
            ("sem elemento focado", { $0.app.focusedUIElement = nil }),
            ("campo de outro processo", { $0.field.pid = terminalPID }),
            ("janela de outro processo", { $0.window.pid = terminalPID }),
        ]
        for (name, mutate) in cases {
            let ax = FakeAccessibility()
            let desktop = Desktop(ax)
            mutate(desktop)
            XCTAssertNil(AccessibilityTextTarget(backend: ax).lock(), "AX-RED: deve recusar \(name)")
        }
    }

    func testTrustSecureInputAndProcessIdentityAreRequiredAtThePress() {
        let cases: [(String, (FakeAccessibility) -> Void)] = [
            ("sem confiança de Acessibilidade", { $0.trusted = false }),
            ("Secure Input ativo", { $0.secureInput = true }),
            ("app em primeiro plano diverge do foco AX", { $0.frontmost = ownPID }),
            ("primeiro plano desconhecido", { $0.frontmost = nil }),
            ("sem app focado", { $0.focusedApp = nil }),
            ("processo encerrado", { $0.identities[textEditPID] = nil }),
            ("sem data de lançamento", {
                $0.identities[textEditPID] = AccessibilityProcess(pid: textEditPID, bundleIdentifier: "com.apple.TextEdit", launchDate: nil)
            }),
        ]
        for (name, mutate) in cases {
            let ax = FakeAccessibility()
            _ = Desktop(ax)
            mutate(ax)
            XCTAssertNil(AccessibilityTextTarget(backend: ax).lock(), "AX-RED: deve recusar \(name)")
            XCTAssertEqual(ax.trustPrompts, 0, "AX-RED: a captura nunca abre o pedido de Acessibilidade")
        }
        ax.trusted = false
        _ = target.lock()
        XCTAssertFalse(ax.log.contains("focusedApplication"), "AX-RED: sem confiança, nenhuma consulta AX")
    }

    // MARK: Revalidation before the single write

    func testChangedDestinationIsNeverWritten() throws {
        let cases: [(String, (Desktop) -> Void)] = [
            ("outro campo focado", { d in
                let other = FakeAXElement(pid: textEditPID, role: .value("AXTextArea"))
                other.window = d.window
                other.selection = AccessibilityTextRange(location: 5, length: 0)
                d.app.focusedUIElement = other
            }),
            ("outra janela focada", { d in
                let other = FakeAXElement(pid: textEditPID, role: .value("AXWindow"))
                other.subrole = .value("AXStandardWindow")
                d.app.focusedWindow = other
                d.field.window = other
            }),
            ("cursor movido", { $0.field.selection = AccessibilityTextRange(location: 6, length: 0) }),
            ("texto selecionado", { $0.field.selection = AccessibilityTextRange(location: 5, length: 2) }),
            ("Terminal em foco", { $0.focusTerminal() }),
            ("TextEdit relançado com o mesmo pid", {
                $0.ax.identities[textEditPID] = AccessibilityProcess(
                    pid: textEditPID, bundleIdentifier: "com.apple.TextEdit", launchDate: launched.addingTimeInterval(60)
                )
            }),
            ("primeiro plano mudou", { $0.ax.frontmost = ownPID }),
            ("campo virou senha", { $0.field.subrole = .value("AXSecureTextField") }),
            ("campo deixou de ser gravável", { $0.field.selectedTextSettable = false }),
        ]
        for (name, mutate) in cases {
            let ax = FakeAccessibility()
            let desktop = Desktop(ax)
            let target = AccessibilityTextTarget(backend: ax)
            let lock = try XCTUnwrap(target.lock(), name)
            mutate(desktop)

            XCTAssertEqual(target.insert(text, into: lock), .notInserted, "AX-RED: destino mudou: \(name)")
            XCTAssertEqual(ax.writeAttempts, [], "AX-RED: nenhuma escrita quando \(name)")
        }
    }

    func testTrustOrSecureInputLostBeforeTheWriteIsNeverWritten() throws {
        let cases: [(String, (FakeAccessibility) -> Void)] = [
            ("confiança revogada", { $0.trusted = false }),
            ("Secure Input ativado", { $0.secureInput = true }),
            ("Secure Input ativado depois da revalidação", { ax in ax.onSelectionRead = { ax.secureInput = true } }),
            ("confiança revogada depois da revalidação", { ax in ax.onSelectionRead = { ax.trusted = false } }),
        ]
        for (name, mutate) in cases {
            let ax = FakeAccessibility()
            _ = Desktop(ax)
            let target = AccessibilityTextTarget(backend: ax)
            let lock = try XCTUnwrap(target.lock(), name)
            mutate(ax)

            XCTAssertEqual(target.insert(text, into: lock), .notInserted, "AX-RED: \(name)")
            XCTAssertEqual(ax.writeAttempts, [], "AX-RED: nenhuma escrita: \(name)")
        }
    }

    // MARK: Write outcome, never retried

    func testUncertainWriteIsUnconfirmedAndNeverRetried() throws {
        ax.writeStatus = .uncertain
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert(text, into: lock), .unconfirmed, "AX-RED: kAXErrorCannotComplete → indeterminado")
        XCTAssertEqual(target.insert(text, into: lock), .notInserted)
        XCTAssertEqual(ax.writeAttempts, [text], "AX-RED: sem retry")
    }

    func testRejectedWriteIsNotInserted() throws {
        ax.writeStatus = .rejected
        let lock = try lockOrFail()

        XCTAssertEqual(target.insert(text, into: lock), .notInserted)
        XCTAssertEqual(ax.writeAttempts, [text])
    }

    func testUnexpectedStateAfterTheWriteIsUnconfirmed() throws {
        let cases: [(String, (FakeAccessibility) -> Void)] = [
            ("cursor no lugar antigo", { $0.caretAfterWrite = { before, _ in before } }),
            ("cursor contado em caracteres", { $0.caretAfterWrite = { before, text in
                AccessibilityTextRange(location: before.location + text.count, length: 0)
            } }),
            ("seleção não vazia", { $0.caretAfterWrite = { before, text in
                AccessibilityTextRange(location: before.location, length: text.utf16.count)
            } }),
            ("cursor ilegível", { $0.caretAfterWrite = { _, _ in nil } }),
            ("faixa escrita difere", { $0.writtenRangeText = { _ in "Ola, cafe" } }),
        ]
        for (name, mutate) in cases {
            let ax = FakeAccessibility()
            _ = Desktop(ax)
            let target = AccessibilityTextTarget(backend: ax)
            let lock = try XCTUnwrap(target.lock(), name)
            mutate(ax)

            XCTAssertEqual(target.insert(text, into: lock), .unconfirmed, "AX-RED: pós incerto: \(name)")
            XCTAssertEqual(ax.writeAttempts.count, 1, "AX-RED: sem retry: \(name)")
        }
    }

    func testNativeWriteErrorsMapToRejectedOrUncertain() {
        XCTAssertEqual(NativeAccessibilityBackend.writeStatus(.success), .success)
        for error in [AXError.cannotComplete, .failure, .notEnoughPrecision] {
            XCTAssertEqual(NativeAccessibilityBackend.writeStatus(error), .uncertain, "AX-RED: \(error.rawValue) é incerto")
        }
        for error in [AXError.attributeUnsupported, .illegalArgument, .invalidUIElement, .apiDisabled, .notImplemented] {
            XCTAssertEqual(NativeAccessibilityBackend.writeStatus(error), .rejected, "AX-RED: \(error.rawValue) não escreveu")
        }
    }
}

// MARK: - The menu's pilot over the real controller, gesture and shortcut binding

/// Transcriber double that answers only when told to, with synthetic text.
@MainActor
private final class PilotTranscriber: Transcriber {
    private var completions: [@Sendable @MainActor (Result<String, Error>) -> Void] = []
    var requests: Int { completions.count }

    func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        completions.append(completion)
        return .finished
    }

    func complete(_ text: String, request index: Int = 0) {
        guard completions.indices.contains(index) else { return XCTFail("no transcription request \(index)") }
        completions[index](.success(text))
    }
}

@MainActor
final class TextEditInsertionPilotTests: XCTestCase {
    private var ax: FakeAccessibility!
    private var desktop: Desktop!
    private var permission: MacFakePermission!
    private var capture: MacFakeCapture!
    private var scheduler: MacFakeScheduler!
    private var transcriber: PilotTranscriber!
    private var hotKeys: RecordingHotKeyBackend!
    private var controller: CaptureController!
    private var settings: HotKeySettings!
    private var pilot: TextEditInsertionPilot!
    private var secureInput = false
    private var updates = 0
    private let transcript = "Olá, mundo 👋 ação"

    override func setUp() async throws {
        ax = FakeAccessibility()
        desktop = Desktop(ax)
        permission = MacFakePermission()
        capture = MacFakeCapture()
        scheduler = MacFakeScheduler()
        transcriber = PilotTranscriber()
        hotKeys = RecordingHotKeyBackend()
        controller = CaptureController(permission: permission, capture: capture, scheduler: scheduler, transcriber: transcriber)
        settings = HotKeySettings(
            capture: controller, scheduler: scheduler, backend: hotKeys,
            microphone: { .authorized }, secureInput: { [unowned self] in secureInput }, firstSendOpen: { false }
        )
        controller.onChange = { [unowned self] in settings.captureChanged() }
        pilot = TextEditInsertionPilot(backend: ax)
        pilot.attach(to: controller) { [unowned self] in updates += 1 }
        settings.enable()
        press()
        release() // arms
    }

    private func press() { hotKeys.deliver(UInt32(kEventHotKeyPressed)) }
    private func release() { hotKeys.deliver(UInt32(kEventHotKeyReleased)) }

    private func holdAndRecord() {
        press()
        permission.answer(true)
        capture.feed(seconds: 2.0)
        XCTAssertEqual(controller.origin, .pushToTalk)
        XCTAssertEqual(controller.phase, .recording)
    }

    private func enablePilot() {
        pilot.toggle()
        XCTAssertTrue(pilot.isEnabled)
    }

    // MARK: Opt-in

    func testOffAtLaunchAndADictationNeverTouchesAccessibility() {
        XCTAssertFalse(pilot.isEnabled, "PILOT-RED: desligado ao iniciar")
        XCTAssertEqual(pilot.status, .off(nil))
        holdAndRecord()
        release()
        transcriber.complete(transcript)

        XCTAssertEqual(ax.log, [], "PILOT-RED: desligado não consulta Acessibilidade")
        XCTAssertEqual(controller.lastOutcome, .transcribed(transcript, duration: 2.0), "PILOT-RED: prévia/Copiar preservados")
        XCTAssertNil(pilot.lastResult)
    }

    func testEnablingWithoutTrustOnlyPromptsOnTheClickAndStaysOff() {
        ax.trusted = false
        XCTAssertEqual(ax.trustPrompts, 0, "PILOT-RED: nada é pedido ao construir")

        pilot.toggle()

        XCTAssertEqual(ax.trustPrompts, 1, "PILOT-RED: o pedido de Acessibilidade só vem do clique")
        XCTAssertFalse(pilot.isEnabled)
        XCTAssertEqual(pilot.status, .off(.needsAccessibility))
        XCTAssertTrue(pilot.menuStatus.contains("Acessibilidade"), pilot.menuStatus)
        XCTAssertEqual(ax.log, ["trusted", "requestTrust"], "PILOT-RED: nenhuma consulta de destino")
    }

    func testTheToggleIsIgnoredWhileASessionRuns() {
        holdAndRecord()
        pilot.toggle()
        XCTAssertFalse(pilot.isEnabled, "PILOT-RED: não liga durante sessão")
        release()
        transcriber.complete(transcript)

        enablePilot()
        holdAndRecord()
        pilot.toggle()
        XCTAssertTrue(pilot.isEnabled, "PILOT-RED: não desliga pelo menu durante sessão")
    }

    // MARK: Valid release

    func testValidReleaseInsertsOnceAndKeepsThePreview() {
        enablePilot()
        holdAndRecord()
        XCTAssertEqual(pilot.lockedProcessIdentifier, textEditPID, "PILOT-RED: destino capturado no press aceito")

        release()
        release()
        transcriber.complete(transcript)
        release()

        XCTAssertEqual(ax.writeAttempts, [transcript], "PILOT-RED: uma inserção, texto exato")
        XCTAssertEqual(pilot.lastResult, .inserted)
        XCTAssertEqual(controller.lastOutcome, .transcribed(transcript, duration: 2.0), "PILOT-RED: Copiar continua disponível")
        XCTAssertGreaterThan(updates, 0, "PILOT-RED: o menu é atualizado após a inserção")
        let status = pilot.resultStatus ?? ""
        XCTAssertFalse(status.contains("mundo"), "PILOT-RED: estado sem conteúdo: \(status)")
    }

    func testMenuStopNeverEndsTheHeldSessionAndAStaleReleaseInsertsNothingMore() {
        enablePilot()
        holdAndRecord()

        controller.stop()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(ax.writeAttempts, [], "PILOT-RED: Parar do menu não insere")
        release()
        transcriber.complete(transcript)
        transcriber.complete("de novo")
        release()

        XCTAssertEqual(ax.writeAttempts, [transcript], "PILOT-RED: só o release válido insere, uma vez")
    }

    func testManualCaptureNeverInspectsTheDestination() {
        enablePilot()
        let reads = ax.log.count
        controller.start()
        permission.answer(true)
        capture.feed(seconds: 2.0)
        controller.stop()
        transcriber.complete(transcript)

        XCTAssertEqual(ax.log.count, reads, "PILOT-RED: captura manual não consulta Acessibilidade")
        XCTAssertNil(pilot.lastResult)
    }

    // MARK: Focus changes and invalidation

    func testAnotherAppActivatedDuringProcessingConsumesTheTarget() {
        enablePilot()
        holdAndRecord()
        release()

        pilot.applicationActivated(pid: terminalPID)
        pilot.applicationActivated(pid: textEditPID) // coming back does not restore it
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [], "PILOT-RED: perda de foco invalida o destino")
        XCTAssertEqual(pilot.lastResult, .notInserted)
        XCTAssertEqual(controller.lastOutcome, .transcribed(transcript, duration: 2.0))
    }

    func testALateActivationOfTheLockedAppItselfKeepsTheTarget() {
        enablePilot()
        holdAndRecord()
        pilot.applicationActivated(pid: textEditPID) // queued before the press, delivered after
        release()
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [transcript])
    }

    func testUnknownActivationInvalidates() {
        enablePilot()
        holdAndRecord()
        pilot.applicationActivated(pid: nil)
        release()
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [])
        XCTAssertEqual(pilot.lastResult, .notInserted)
    }

    func testFirstSendQuestionInvalidatesTheTarget() {
        enablePilot()
        holdAndRecord()
        release()

        pilot.invalidate() // the app calls it right before FirstSendPrompt.ask
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [], "PILOT-RED: 1º envio consome o destino")
        XCTAssertEqual(pilot.lastResult, .notInserted)
    }

    func testTerminalFocusedAtThePressFallsBackToThePreview() {
        enablePilot()
        desktop.focusTerminal()
        holdAndRecord()
        release()
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [], "PILOT-RED: nada é enviado ao Terminal")
        XCTAssertEqual(pilot.lastResult, .notInserted)
        XCTAssertFalse(ax.log.contains("focusedUIElement"), "PILOT-RED: o Terminal não é inspecionado")
        XCTAssertEqual(controller.lastOutcome, .transcribed(transcript, duration: 2.0))
    }

    func testFocusMovedInsideTextEditBeforeTheResultIsNotWritten() {
        enablePilot()
        holdAndRecord()
        release()
        desktop.field.selection = AccessibilityTextRange(location: 0, length: 0)
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [])
        XCTAssertEqual(pilot.lastResult, .notInserted)
    }

    func testSecureInputOnlyDuringProcessingBlocksTheWrite() {
        enablePilot()
        holdAndRecord()
        release()
        ax.secureInput = true
        transcriber.complete(transcript)

        XCTAssertEqual(ax.writeAttempts, [])
        XCTAssertEqual(pilot.lastResult, .notInserted)
    }

    func testSecureInputAtTheReleaseDiscardsWithoutWriting() {
        enablePilot()
        holdAndRecord()
        secureInput = true
        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(transcriber.requests, 0)
        XCTAssertEqual(ax.writeAttempts, [])
        XCTAssertNil(pilot.lastResult, "PILOT-RED: descartado não tem estado de inserção")
    }

    func testUnconfirmedWriteIsReportedWithoutContent() {
        enablePilot()
        ax.writeStatus = .uncertain
        holdAndRecord()
        release()
        transcriber.complete(transcript)

        XCTAssertEqual(pilot.lastResult, .unconfirmed)
        XCTAssertEqual(ax.writeAttempts.count, 1)
        XCTAssertFalse((pilot.resultStatus ?? "").contains("mundo"))
    }

    // MARK: Suspension and quit

    /// In the app's order: the pilot first, then the controller and the shortcut.
    func testSuspensionDisablesThePilotAndReleasesTheTarget() {
        enablePilot()
        holdAndRecord()

        pilot.disable(.suspended)
        XCTAssertNil(pilot.lockedProcessIdentifier, "PILOT-RED: suspensão libera o destino")
        controller.suspend()
        settings.suspend()

        XCTAssertFalse(pilot.isEnabled)
        XCTAssertEqual(pilot.status, .off(.suspended))
        XCTAssertTrue(pilot.menuStatus.contains("suspensão"), pilot.menuStatus)
        XCTAssertNil(pilot.lastResult)
        let reads = ax.log.count
        press()
        release()
        press()
        XCTAssertEqual(ax.log.count, reads, "PILOT-RED: nada volta a ligar sozinho")
    }

    func testQuitDisablesThePilotBeforeTheSessionEnds() {
        enablePilot()
        holdAndRecord()
        release()

        pilot.disable()
        XCTAssertNil(pilot.lockedProcessIdentifier)
        settings.disable()
        controller.cancel()
        transcriber.complete(transcript)

        XCTAssertFalse(pilot.isEnabled)
        XCTAssertEqual(ax.writeAttempts, [], "PILOT-RED: encerrar o app não insere")
    }
}
