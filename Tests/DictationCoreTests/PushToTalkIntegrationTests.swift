@testable import DictationCore
import XCTest

/// The real controller driven by the real gesture core, over the app's real cloud path (consent gate
/// and OpenAI adapter) with a fake transport, permission, device, scheduler and monotonic clock.
/// No microphone, keyboard, keychain, network or clipboard.
@MainActor
final class PushToTalkIntegrationTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!
    private var clock: TestClock!
    private var transport: FakeTransport!
    private var consent: CloudConsent!
    private var confirmer: FakeConfirmer!
    private var controller: CaptureController!
    private var gesture: PushToTalk!
    private var secureInput = false
    private let registration = UUID()
    /// Like the app: the first-send question takes focus, so it invalidates the insertion target first.
    private var beforeFirstSendQuestion: (() -> Void)?
    private var target: IntegrationInsertionTarget!
    private var insertion: TextInsertionCoordinator!
    private var insertionResults: [TextInsertionResult?] = []

    override func setUp() async throws {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        clock = TestClock()
        transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()
        confirmer = FakeConfirmer()
        let confirmation = confirmer.confirmation
        let cloud = CloudTranscription.openAI(
            keys: FakeKeyStore(placeholderKey), consent: consent,
            confirmFirstSend: { [unowned self] duration, reply in
                beforeFirstSendQuestion?()
                return confirmation(duration, reply)
            },
            queue: ManualKeychainQueue(), transport: transport
        )
        let clock = clock!
        controller = CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: cloud.transcriber,
            now: { clock.now }
        )
        gesture = makeGesture(scheduler: scheduler)
    }

    /// Composed like the app: the gesture sees every capture transition. Armed by one release.
    private func makeGesture(scheduler: Scheduler) -> PushToTalk {
        let clock = clock!
        let gesture = PushToTalk(
            capture: controller, scheduler: scheduler, maximumHold: 25, now: { clock.now },
            blocked: { [unowned self] in self.secureInput }
        )
        controller.onChange = { [weak gesture] in gesture?.captureChanged() }
        gesture.activate(registration: registration)
        gesture.receive(.released, registration: registration)
        return gesture
    }

    private func press() { gesture.receive(.pressed, registration: registration) }
    private func release() { gesture.receive(.released, registration: registration) }

    /// Time passes for the clock and for every timer due meanwhile.
    private func wait(_ seconds: Double) {
        clock.advance(by: seconds)
        scheduler.advance(by: seconds)
    }

    private func pressAndRecord(seconds: Double = 2.0) {
        press()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: seconds))
    }

    private func sessionEnded() -> XCTestExpectation {
        let ended = expectation(description: "session ended")
        let gesture = gesture
        controller.onChange = { [controller] in
            gesture?.captureChanged()
            if controller?.phase == .idle { ended.fulfill() }
        }
        return ended
    }

    // MARK: The only path that sends

    func testValidReleaseSendsTheClipExactlyOnce() async {
        pressAndRecord()
        wait(3)
        let ended = sessionEnded()

        release()
        release()
        XCTAssertEqual(controller.phase, .processing)
        await fulfillment(of: [ended], timeout: 5)
        release()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url, OpenAITranscriber.endpoint)
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        XCTAssertFalse(capture.isRunning)
    }

    func testFirstHeldClipStillAsksBeforeSending() async {
        consent.revoke()
        consent.grant()
        pressAndRecord()
        let ended = sessionEnded()

        release()
        XCTAssertEqual(confirmer.asked, [2.0])
        XCTAssertTrue(transport.requests.isEmpty)
        confirmer.answer(true)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testReleaseWithoutConsentSendsNothing() {
        consent.revoke()
        pressAndRecord()

        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Permission and the deadline

    func testGrantAfterTheDeadlineNeverOpensTheMicrophone() {
        press()
        clock.advance(by: 25) // the watchdog has not been delivered

        permission.answer(true)
        release()

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReleaseWhilePermissionIsPendingMakesALateGrantRecordNothing() {
        press()
        release()

        permission.answer(true)

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testHoldingUntilTheDeadlineDiscardsAndTheLateReleaseSendsNothing() {
        pressAndRecord()

        wait(25)
        release()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAudioAfterTheDeadlineDiscardsEvenIfNoTimerRan() {
        pressAndRecord(seconds: 1.0)
        clock.advance(by: 25)

        capture.feed(Synthetic.tone(seconds: 0.1))
        release()

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 1.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReleaseAfterTheDeadlineDiscardsEvenIfNoTimerRan() {
        pressAndRecord()
        clock.advance(by: 25)

        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testControllerWatchdogDiscardsEvenIfTheGestureWatchdogNeverRuns() {
        gesture = makeGesture(scheduler: FakeScheduler()) // its timers are never delivered
        pressAndRecord()

        wait(25)
        release()

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Ownership

    func testMenuStopCannotSubmitAHeldSession() async {
        pressAndRecord()

        controller.stop()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(transport.requests.isEmpty)
        let ended = sessionEnded()
        release()
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1, "only the release submits")
    }

    func testSecureInputAtReleaseDiscardsUnsent() {
        pressAndRecord()
        secureInput = true

        release()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSecureInputAtPressOpensNothing() {
        secureInput = true

        press()

        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testPressAndReleaseDuringAManualSessionNeverTouchIt() async throws {
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        let manual = try XCTUnwrap(controller.sessionID)

        press()
        release()
        press()
        wait(25)
        release()
        XCTAssertEqual(controller.sessionID, manual)
        XCTAssertEqual(controller.origin, .manual)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(transport.requests.isEmpty)

        let ended = sessionEnded()
        controller.stop()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(transport.requests.count, 1, "the manual session submits through Parar as before")
    }

    // MARK: Text insertion pilot (controller hooks + coordinator + consent gate)

    /// Wired like the app: lock at the accepted press, finish once per session, invalidate before the
    /// first-send question.
    private func wireInsertion(enabled: Bool = true) {
        target = IntegrationInsertionTarget()
        target.permissionRequestsAtLock = { [unowned self] in permission.requests }
        insertion = TextInsertionCoordinator(target: target)
        insertion.setEnabled(enabled)
        controller.onPushToTalkAccepted = { [unowned self] id in
            guard insertion.isEnabled, let lock = target.lock() else { return }
            insertion.bind(lock, to: id)
        }
        controller.onFinish = { [unowned self] id, origin, outcome in
            insertionResults.append(insertion.finish(session: id, origin: origin, outcome: outcome))
        }
        beforeFirstSendQuestion = { [unowned self] in insertion.invalidate() }
    }

    func testValidReleaseInsertsTheTranscriptOnceIntoTheTargetLockedAtThePress() async throws {
        wireInsertion()
        pressAndRecord()
        let lock = try XCTUnwrap(target.issued.first, "INS-RED: o destino é capturado no press aceito")
        XCTAssertEqual(target.permissionRequestsSeenAtLock, [0], "INS-RED: captura antes de pedir o microfone")
        wait(3)
        let ended = sessionEnded()

        release()
        release()
        await fulfillment(of: [ended], timeout: 5)
        release()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(target.inserts.map(\.text), ["Ditado sintético."], "INS-RED: uma única inserção")
        XCTAssertEqual(target.inserts.map(\.token), [lock.token])
        XCTAssertEqual(target.releases, [lock.token], "INS-RED: o lock é liberado exatamente uma vez")
        XCTAssertEqual(insertionResults, [.inserted])
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0),
                       "INS-RED: prévia e Copiar continuam disponíveis")
    }

    func testFirstSendQuestionConsumesTheTargetSoTheConfirmedClipIsNotInserted() async throws {
        consent.revoke()
        consent.grant()
        wireInsertion()
        pressAndRecord()
        let lock = try XCTUnwrap(target.issued.first)
        let ended = sessionEnded()

        release()
        XCTAssertEqual(confirmer.asked, [2.0])
        XCTAssertEqual(target.releases, [lock.token], "INS-RED: a pergunta do 1º envio invalida o destino antes de aparecer")
        confirmer.answer(true)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(target.inserts.count, 0, "INS-RED: 1º envio confirmado não insere")
        XCTAssertEqual(target.releases, [lock.token])
        XCTAssertEqual(insertionResults, [nil])
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0), "INS-RED: Copiar preservado")
    }

    func testMenuStopAndTheDeadlineNeverInsertAndALateReleaseChangesNothing() throws {
        wireInsertion()
        pressAndRecord()
        let lock = try XCTUnwrap(target.issued.first)

        controller.stop()
        XCTAssertEqual(insertionResults, [], "INS-RED: Parar do menu não encerra a sessão PTT")
        wait(25)
        release()
        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertEqual(target.inserts.count, 0)
        XCTAssertEqual(target.releases, [lock.token])
        XCTAssertEqual(insertionResults, [nil], "INS-RED: um fim, sem inserção")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReleaseWhilePermissionIsPendingReleasesTheLockAndALateGrantInsertsNothing() throws {
        wireInsertion()
        press()
        let lock = try XCTUnwrap(target.issued.first)

        release()
        permission.answer(true)

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(target.releases, [lock.token])
        XCTAssertEqual(target.inserts.count, 0)
        XCTAssertEqual(insertionResults, [nil])
    }

    func testSecureInputAtReleaseDiscardsAndInsertsNothing() throws {
        wireInsertion()
        pressAndRecord()
        let lock = try XCTUnwrap(target.issued.first)
        secureInput = true

        release()

        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(target.inserts.count, 0)
        XCTAssertEqual(target.releases, [lock.token])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testManualSessionNeverLocksOrInserts() async {
        wireInsertion()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        let ended = sessionEnded()

        controller.stop()
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(target.issued.count, 0, "INS-RED: sessão manual não captura destino")
        XCTAssertEqual(target.inserts.count, 0)
        XCTAssertEqual(insertionResults, [nil])
    }

    func testDisabledPilotTakesNoLockAndKeepsThePreview() async {
        wireInsertion(enabled: false)
        pressAndRecord()
        let ended = sessionEnded()

        release()
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(target.issued.count, 0, "INS-RED: desligado não consulta o destino")
        XCTAssertEqual(target.inserts.count, 0)
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
    }
}

/// Destination double for the integration: issues locks, records inserts and releases.
@MainActor
private final class IntegrationInsertionTarget: TextInsertionTarget {
    var issued: [TextInsertionLock] = []
    var inserts: [(text: String, token: UUID)] = []
    var releases: [UUID] = []
    var permissionRequestsAtLock: (() -> Int)?
    var permissionRequestsSeenAtLock: [Int] = []

    func lock() -> TextInsertionLock? {
        permissionRequestsSeenAtLock.append(permissionRequestsAtLock?() ?? -1)
        let lock = TextInsertionLock(token: UUID())
        issued.append(lock)
        return lock
    }

    func insert(_ text: String, into lock: TextInsertionLock) -> TextInsertionResult {
        inserts.append((text, lock.token))
        return .inserted
    }

    func release(_ lock: TextInsertionLock) {
        releases.append(lock.token)
    }
}
