import DictationCore
import XCTest

/// Sessions opened by the push-to-talk gesture: proposed ID, monotonic deadline, release-only submit.
@MainActor
final class PushToTalkCaptureTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!
    private var clock: TestClock!
    private var transcriber: FakeTranscriber!

    private func makeController(limits: CaptureLimits = CaptureLimits()) -> CaptureController {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        clock = TestClock()
        transcriber = FakeTranscriber()
        let clock = clock!
        return CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: transcriber,
            limits: limits, now: { clock.now }
        )
    }

    /// Proposes a held session with `hold` seconds left, grants access and records `seconds` of tone.
    private func makeHeldRecording(
        hold: Double = 25, seconds: Double = 2.0, limits: CaptureLimits = CaptureLimits()
    ) -> (CaptureController, UUID) {
        let controller = makeController(limits: limits)
        let id = UUID()
        XCTAssertEqual(controller.start(proposing: id, deadline: clock.now.advanced(by: .seconds(hold))), .accepted(id))
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: seconds))
        return (controller, id)
    }

    // MARK: Proposal

    func testProposalInstallsTheGivenIDAsAPushToTalkSession() {
        let controller = makeController()
        let id = UUID()

        let answer = controller.start(proposing: id, deadline: clock.now.advanced(by: .seconds(25)))

        XCTAssertEqual(answer, .accepted(id))
        XCTAssertEqual(controller.sessionID, id)
        XCTAssertEqual(controller.origin, .pushToTalk)
        XCTAssertEqual(controller.phase, .awaitingPermission)
        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(capture.starts, 0)
    }

    func testManualStartIsMarkedManual() {
        let controller = makeController()

        controller.start()

        XCTAssertEqual(controller.origin, .manual)
    }

    func testProposalIsRejectedWhileAnotherSessionRuns() {
        let controller = makeController()
        controller.start()
        let manual = controller.sessionID

        let answer = controller.start(proposing: UUID(), deadline: clock.now.advanced(by: .seconds(25)))

        XCTAssertEqual(answer, .rejected)
        XCTAssertEqual(controller.sessionID, manual)
        XCTAssertEqual(controller.origin, .manual)
        XCTAssertEqual(permission.requests, 1)
    }

    func testProposalAtOrPastItsDeadlineIsRejectedWithoutAskingPermission() {
        for offset in [0.0, -1.0] {
            let controller = makeController()

            let answer = controller.start(proposing: UUID(), deadline: clock.now.advanced(by: .seconds(offset)))

            XCTAssertEqual(answer, .rejected, "offset \(offset)")
            XCTAssertEqual(controller.phase, .idle)
            XCTAssertNil(controller.sessionID)
            XCTAssertEqual(permission.requests, 0)
        }
    }

    func testOriginIsClearedWhenTheSessionEnds() {
        let (controller, id) = makeHeldRecording()

        controller.cancel(session: id)

        XCTAssertNil(controller.origin)
        XCTAssertNil(controller.sessionID)
    }

    // MARK: Monotonic deadline around the microphone

    func testGrantAtOrAfterTheDeadlineNeverOpensTheMicrophone() {
        for late in [0.0, 3.0] {
            let controller = makeController()
            let id = UUID()
            _ = controller.start(proposing: id, deadline: clock.now.advanced(by: .seconds(5)))
            clock.advance(by: 5 + late)

            permission.answer(true)

            XCTAssertEqual(capture.starts, 0, "late \(late)")
            XCTAssertEqual(controller.phase, .idle)
            XCTAssertNil(controller.sessionID)
            XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 0))
        }
    }

    func testGrantJustBeforeTheDeadlineOpensTheMicrophone() {
        let controller = makeController()
        _ = controller.start(proposing: UUID(), deadline: clock.now.advanced(by: .seconds(5)))
        clock.advance(by: 4.99)

        permission.answer(true)

        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(controller.phase, .recording)
    }

    func testDeadlinePassingWhileTheDeviceOpensClosesItWithoutRecording() {
        let controller = makeController()
        var phases: [CaptureController.Phase] = []
        controller.onChange = { phases.append(controller.phase) }
        _ = controller.start(proposing: UUID(), deadline: clock.now.advanced(by: .seconds(5)))
        capture.duringStart = { [clock] in clock!.advance(by: 5) }

        permission.answer(true)

        XCTAssertEqual(capture.starts, 1)
        XCTAssertFalse(capture.isRunning, "the device opened past the deadline must be released")
        XCTAssertEqual(phases, [.awaitingPermission, .idle], "never reported as recording")
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 0))
    }

    func testAudioArrivingAfterTheDeadlineEndsTheSessionUnsent() {
        let (controller, _) = makeHeldRecording(hold: 5, seconds: 1.0)
        clock.advance(by: 5)

        capture.feed(Synthetic.tone(seconds: 0.1))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 1.0))
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    // MARK: Watchdog: discard, never the manual auto-stop

    func testHeldSessionTimerFiresAtTheDeadlineAndDiscards() {
        let (controller, _) = makeHeldRecording(hold: 25)

        scheduler.advance(by: 24.9)
        XCTAssertEqual(controller.phase, .recording)
        scheduler.advance(by: 0.1)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transcriber.received.isEmpty, "a held session must never auto-submit")
    }

    func testHeldSessionTimerUsesTheRemainingTimeAfterAPermissionWait() {
        let controller = makeController()
        _ = controller.start(proposing: UUID(), deadline: clock.now.advanced(by: .seconds(25)))
        clock.advance(by: 10)
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))

        scheduler.advance(by: 14.9)
        XCTAssertEqual(controller.phase, .recording)
        scheduler.advance(by: 0.1)

        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    func testHeldSessionCaptureLimitDiscardsWhenShorterThanTheDeadline() {
        var limits = CaptureLimits()
        limits.maxDuration = 10
        let (controller, _) = makeHeldRecording(hold: 25, limits: limits)

        scheduler.advance(by: 10)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    // MARK: Stop and cancel by session

    func testReleaseOfTheOwnSessionBeforeTheDeadlineSubmitsOnce() {
        let (controller, id) = makeHeldRecording(hold: 25)
        clock.advance(by: 24.99)

        controller.stop(session: id)
        controller.stop(session: id)

        XCTAssertEqual(controller.phase, .processing)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(transcriber.received.map(\.duration), [2.0])
    }

    func testReleaseAtOrAfterTheDeadlineDiscardsEvenIfTheTimerDidNotRun() {
        for late in [0.0, 0.5] {
            let (controller, id) = makeHeldRecording(hold: 25)
            clock.advance(by: 25 + late)

            controller.stop(session: id)

            XCTAssertEqual(controller.phase, .idle, "late \(late)")
            XCTAssertFalse(capture.isRunning)
            XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 2.0))
            XCTAssertTrue(transcriber.received.isEmpty)
        }
    }

    func testStopOfASessionStillAwaitingPermissionDiscardsAndIgnoresALateGrant() {
        let controller = makeController()
        let id = UUID()
        _ = controller.start(proposing: id, deadline: clock.now.advanced(by: .seconds(25)))

        controller.stop(session: id)
        permission.answer(true)

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 0))
    }

    func testStopOfAnExpiredPendingPermissionReportsDeadlineAndIgnoresGrant() {
        let controller = makeController()
        let id = UUID()
        _ = controller.start(proposing: id, deadline: clock.now.advanced(by: .seconds(5)))
        clock.advance(by: 5)

        controller.stop(session: id)
        permission.answer(true)

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.pushToTalkExpired, duration: 0))
    }

    func testManualStopCannotEndAHeldSession() {
        let (controller, id) = makeHeldRecording()

        controller.stop()

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.sessionID, id)
        XCTAssertTrue(capture.isRunning)
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    func testStopOrCancelNamingAnotherSessionDoesNothing() {
        let (controller, id) = makeHeldRecording()

        controller.stop(session: UUID())
        controller.cancel(session: UUID())

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.sessionID, id)
        XCTAssertTrue(capture.isRunning)
    }

    func testSessionCallsNeverTouchAManualSessionEvenWithItsID() throws {
        let controller = makeController()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        let manual = try XCTUnwrap(controller.sessionID)

        controller.stop(session: manual)
        controller.cancel(session: manual)

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.origin, .manual)
        XCTAssertTrue(transcriber.received.isEmpty)
    }

    func testCancelOfTheOwnSessionDiscardsAsCancelledBeforeTheDeadlineAndExpiredAfter() {
        for (elapsed, reason) in [(24.9, DiscardReason.cancelled), (25, .pushToTalkExpired)] {
            let (controller, id) = makeHeldRecording(hold: 25)
            clock.advance(by: elapsed)

            controller.cancel(session: id)

            XCTAssertEqual(controller.lastOutcome, .discarded(reason, duration: 2.0), "elapsed \(elapsed)")
            XCTAssertFalse(capture.isRunning)
            XCTAssertTrue(transcriber.received.isEmpty)
        }
    }

    func testMenuCancelAndSuspensionStillEndAHeldSession() {
        for suspend in [false, true] {
            let (controller, _) = makeHeldRecording()

            if suspend { controller.suspend() } else { controller.cancel() }

            XCTAssertEqual(controller.lastOutcome, .discarded(suspend ? .suspended : .cancelled, duration: 2.0))
            XCTAssertFalse(capture.isRunning)
        }
    }

    func testManualSessionKeepsItsAutomaticStop() {
        let controller = makeController()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        clock.advance(by: 100)

        scheduler.advance(by: 30)

        XCTAssertEqual(transcriber.received.map(\.duration), [2.0], "manual capture still submits at its limit")
    }

    func testExpiredMessageSaysNothingWasSent() {
        XCTAssertEqual(
            Outcome.discarded(.pushToTalkExpired, duration: 1).message,
            "Prazo do atalho esgotado — áudio descartado sem envio (1,0 s)"
        )
    }
}
