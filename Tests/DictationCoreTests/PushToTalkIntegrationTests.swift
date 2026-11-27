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
        let cloud = CloudTranscription.openAI(
            keys: FakeKeyStore(placeholderKey), consent: consent, confirmFirstSend: confirmer.confirmation,
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
}
