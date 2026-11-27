import Carbon
import DictationCore
@testable import DictationMac
import XCTest

/// The menu's push-to-talk binding over the real controller and gesture core. The Carbon calls are
/// replaced by a recording backend: no shortcut is registered, no key event is posted, and the
/// microphone, Secure Input and first-send states are injected.
@MainActor
final class HotKeySettingsTests: XCTestCase {
    private var permission: MacFakePermission!
    private var capture: MacFakeCapture!
    private var scheduler: MacFakeScheduler!
    private var transcriber: MacFakeTranscriber!
    private var backend: RecordingHotKeyBackend!
    private var controller: CaptureController!
    private var settings: HotKeySettings!
    private var microphone = MicrophoneAccess.authorized
    private var microphoneReads = 0
    private var secureInput = false
    private var firstSendOpen = false
    private var renders = 0

    override func setUp() async throws {
        permission = MacFakePermission()
        capture = MacFakeCapture()
        scheduler = MacFakeScheduler()
        transcriber = MacFakeTranscriber()
        backend = RecordingHotKeyBackend()
        controller = CaptureController(permission: permission, capture: capture, scheduler: scheduler, transcriber: transcriber)
        settings = HotKeySettings(
            capture: controller, scheduler: scheduler, backend: backend,
            microphone: { [unowned self] in microphoneReads += 1; return microphone },
            secureInput: { [unowned self] in secureInput },
            firstSendOpen: { [unowned self] in firstSendOpen }
        )
        controller.onChange = { [unowned self] in settings.captureChanged() }
        settings.onChange = { [unowned self] in renders += 1 }
    }

    private func press() { backend.deliver(UInt32(kEventHotKeyPressed)) }
    private func release() { backend.deliver(UInt32(kEventHotKeyReleased)) }

    /// Enabled, armed by one press and release, then held and recording.
    private func holdAndRecord() {
        settings.enable()
        press()
        release()
        press()
        permission.answer(true)
        capture.feed(seconds: 2.0)
        XCTAssertEqual(controller.origin, .pushToTalk)
        XCTAssertEqual(controller.phase, .recording)
    }

    // MARK: Opt-in

    func testOffAtLaunchAndConstructionTouchesNoKeyOrMicrophone() {
        XCTAssertEqual(settings.status, .off(nil))
        XCTAssertEqual(settings.shortcut, .d)
        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(microphoneReads, 0)
        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(settings.menuStatus, "Atalho de gravação: desativado")
    }

    func testEnablingOrChangingTheChordDuringManualCaptureDoesNothing() {
        controller.start()

        settings.enable()
        settings.select(.g)

        XCTAssertEqual(settings.status, .off(nil))
        XCTAssertEqual(settings.shortcut, .d)
        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(permission.requests, 1, "the existing manual permission request is unchanged")
    }

    func testShortcutsAreAFixedListOfCtrlShiftLetters() {
        XCTAssertEqual(PushToTalkShortcut.allCases.map(\.title), ["Ctrl+Shift+D", "Ctrl+Shift+G", "Ctrl+Shift+J", "Ctrl+Shift+K"])
        XCTAssertEqual(
            PushToTalkShortcut.allCases.map(\.chord.keyCode),
            [kVK_ANSI_D, kVK_ANSI_G, kVK_ANSI_J, kVK_ANSI_K].map(UInt32.init)
        )
        for shortcut in PushToTalkShortcut.allCases {
            XCTAssertEqual(shortcut.chord.modifiers, UInt32(controlKey | shiftKey), shortcut.title)
            XCTAssertTrue(shortcut.chord.isValid, shortcut.title)
        }
    }

    func testEnablingWithoutMicrophoneAccessOnlyReadsItAndPointsToIniciar() {
        for (access, reason, hint) in [
            (MicrophoneAccess.notDetermined, HotKeySettings.OffReason.microphoneNotDetermined, "Iniciar"),
            (.denied, .microphoneDenied, "Ajustes do Sistema"),
        ] {
            microphone = access

            settings.enable()

            XCTAssertEqual(settings.status, .off(reason))
            XCTAssertEqual(backend.operations, [], "nothing is registered without microphone access")
            XCTAssertEqual(permission.requests, 0, "enabling never asks for the microphone")
            XCTAssertTrue(settings.menuStatus.contains(hint), settings.menuStatus)
        }
        XCTAssertEqual(microphoneReads, 2)
    }

    func testEnablingRegistersOnlyTheChosenChordAndTheFirstPressOnlyArms() {
        settings.enable()

        XCTAssertEqual(settings.status, .active)
        XCTAssertEqual(backend.operations, ["install", "register"])
        XCTAssertEqual(backend.chord, PushToTalkShortcut.d.chord)
        XCTAssertEqual(settings.menuStatus, "Ctrl+Shift+D ativo: pressione e solte uma vez para armar (esse toque não grava)")
        press()
        XCTAssertEqual(controller.phase, .idle, "the first press after enabling only arms")
        XCTAssertEqual(permission.requests, 0)
        release()
        XCTAssertEqual(settings.menuStatus, "Ctrl+Shift+D pronto: segure para gravar e solte para encerrar")

        press()

        XCTAssertEqual(controller.origin, .pushToTalk)
        XCTAssertEqual(controller.phase, .awaitingPermission)
        XCTAssertEqual(settings.menuStatus, "Ctrl+Shift+D pressionado: solte para encerrar")
    }

    func testAdapterEventsAreRendered() {
        settings.enable()
        let before = renders

        press()
        release()

        XCTAssertEqual(renders, before + 2)
    }

    // MARK: Failure keeps manual capture

    func testConflictLeavesTheShortcutOffAndManualCaptureWorking() {
        backend.registerError = CarbonHotKey.Failure.native(OSStatus(eventHotKeyExistsErr))

        settings.enable()

        XCTAssertEqual(settings.status, .off(.conflict))
        XCTAssertEqual(backend.operations, ["install", "register", "remove"])
        XCTAssertFalse(backend.isRegistered)
        XCTAssertEqual(settings.menuStatus, "Ctrl+Shift+D já está em uso — use Iniciar e Parar")
        controller.start()
        XCTAssertEqual(controller.origin, .manual)
        XCTAssertEqual(controller.phase, .awaitingPermission)
    }

    func testOtherRegistrationFailureLeavesTheShortcutOff() {
        backend.registerError = CarbonHotKey.Failure.native(OSStatus(paramErr))

        settings.enable()

        XCTAssertEqual(settings.status, .off(.failed))
        XCTAssertEqual(settings.menuStatus, "Não foi possível registrar Ctrl+Shift+D — use Iniciar e Parar")
    }

    // MARK: Teardown: cancel, unregister, stay off

    func testDisablingCancelsTheHeldSessionUnregistersAndIgnoresLateEvents() {
        holdAndRecord()

        settings.disable()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(backend.operations, ["install", "register", "unregister", "remove"])
        XCTAssertEqual(settings.status, .off(.disabled))
        release()
        press()
        XCTAssertEqual(controller.phase, .idle, "an event queued before teardown is ignored")
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    func testSuspensionCancelsUnregistersAndNeverReenables() {
        holdAndRecord()

        controller.suspend()
        settings.suspend()
        scheduler.advance(by: 60)
        press()

        XCTAssertEqual(controller.lastOutcome, .discarded(.suspended, duration: 2.0))
        XCTAssertEqual(backend.operations, ["install", "register", "unregister", "remove"])
        XCTAssertEqual(settings.status, .off(.suspended))
        XCTAssertEqual(settings.menuStatus, "Atalho desativado pela suspensão — ative de novo para usar")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testSuspensionWhileOffKeepsItsState() {
        settings.suspend()

        XCTAssertEqual(settings.status, .off(nil))
        XCTAssertEqual(backend.operations, [])
    }

    func testChoosingAnotherLetterCancelsUnregistersAndLeavesItOff() {
        holdAndRecord()

        settings.select(.g)

        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(backend.operations, ["install", "register", "unregister", "remove"])
        XCTAssertEqual(settings.status, .off(.reconfigured))
        XCTAssertEqual(settings.shortcut, .g)
        XCTAssertEqual(settings.menuStatus, "Combinação trocada para Ctrl+Shift+G — ative o atalho de novo para usar")
        settings.enable()
        XCTAssertEqual(backend.chord, PushToTalkShortcut.g.chord)
    }

    func testEventsDeliveredDuringTeardownAreIgnored() {
        settings.enable()
        press()
        release()
        backend.duringUnregister = { [unowned self] in
            press()
            release()
            press()
        }

        settings.disable()

        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: Blocks: settings dialogs, first-send question, Secure Input

    func testPressDuringASettingsDialogStartsNothingAndTheReleaseStillArms() {
        settings.enable()
        press()
        release()

        settings.duringSettingsDialog {
            XCTAssertTrue(settings.isBlocked)
            press()
            release()
        }
        XCTAssertEqual(permission.requests, 0)
        XCTAssertFalse(settings.isBlocked)
        press()

        XCTAssertEqual(controller.origin, .pushToTalk)
    }

    func testPressWhileTheFirstSendQuestionIsOpenOrUnderSecureInputStartsNothing() {
        for block in 0..<2 {
            setUpBlock(block, on: true)
            settings.enable()
            press()
            release()

            press()

            XCTAssertTrue(settings.isBlocked)
            XCTAssertEqual(permission.requests, 0)
            settings.disable()
            setUpBlock(block, on: false)
        }
    }

    private func setUpBlock(_ block: Int, on: Bool) {
        if block == 0 { firstSendOpen = on } else { secureInput = on }
    }

    func testSecureInputAtReleaseDiscardsTheHeldClipUnsent() {
        holdAndRecord()
        secureInput = true

        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertTrue(transcriber.received.isEmpty)
        XCTAssertEqual(settings.menuStatus, "Ctrl+Shift+D bloqueado: entrada segura ativa (campo de senha)")
    }

    func testValidReleaseHandsTheClipToTheTranscriberOnce() {
        holdAndRecord()

        release()
        release()

        XCTAssertEqual(transcriber.received.count, 1)
        XCTAssertEqual(controller.phase, .processing)
    }
}

// MARK: Fakes (the core test target's fakes are not visible here)

@MainActor
final class RecordingHotKeyBackend: CarbonHotKeyBackend {
    var operations: [String] = []
    var registerError: Error?
    var chord: CarbonHotKey.Chord?
    var duringUnregister: (() -> Void)?
    private(set) var isRegistered = false
    private var handler: (@MainActor (CarbonHotKeyEvent) -> Bool)?
    /// Kept after removal, like an event Carbon had already queued.
    private var lastHandler: (@MainActor (CarbonHotKeyEvent) -> Bool)?
    private var signature: UInt32 = 0
    private var id: UInt32 = 0

    func install(_ handler: @escaping @MainActor (CarbonHotKeyEvent) -> Bool) throws {
        operations.append("install")
        self.handler = handler
        lastHandler = handler
    }

    func register(_ chord: CarbonHotKey.Chord, signature: UInt32, id: UInt32) throws {
        operations.append("register")
        if let registerError { throw registerError }
        self.chord = chord
        self.signature = signature
        self.id = id
        isRegistered = true
    }

    func unregister() {
        guard isRegistered else { return }
        operations.append("unregister")
        isRegistered = false
        duringUnregister?()
    }

    func removeHandler() {
        guard handler != nil else { return }
        operations.append("remove")
        handler = nil
    }

    @discardableResult
    func deliver(_ kind: UInt32) -> Bool {
        lastHandler?(CarbonHotKeyEvent(eventClass: UInt32(kEventClassKeyboard), kind: kind, signature: signature, id: id)) ?? false
    }
}

@MainActor
final class MacFakePermission: MicrophonePermission {
    private(set) var requests = 0
    private var pending: [@Sendable @MainActor (Bool) -> Void] = []

    func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        requests += 1
        pending.append(completion)
    }

    func answer(_ granted: Bool) {
        let answers = pending
        pending = []
        answers.forEach { $0(granted) }
    }
}

@MainActor
final class MacFakeCapture: AudioCapture {
    private(set) var isRunning = false
    private var sink: (@Sendable @MainActor (AudioChunk) -> Void)?

    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws {
        isRunning = true
        sink = onChunk
    }

    func stop() { isRunning = false }

    /// Synthetic 440 Hz tone at 48 kHz; never real speech.
    func feed(seconds: Double) {
        let rate = 48_000.0
        let samples = (0..<Int(seconds * rate)).map { Float(0.1 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        sink?(AudioChunk(samples: samples, sampleRate: rate))
    }
}

@MainActor
final class MacFakeScheduler: Scheduler {
    private var now: TimeInterval = 0
    private var timers: [(due: TimeInterval, action: @Sendable @MainActor () -> Void)] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        timers.append((now + delay, action))
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = timers.filter { $0.due <= now }.sorted { $0.due < $1.due }
        timers.removeAll { $0.due <= now }
        due.forEach { $0.action() }
    }
}

@MainActor
final class MacFakeTranscriber: Transcriber {
    private(set) var received: [CapturedAudio] = []

    func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        received.append(audio)
        return .finished
    }
}
