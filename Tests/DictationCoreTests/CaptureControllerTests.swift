import DictationCore
import XCTest

@MainActor
final class CaptureControllerTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!

    private func makeController(transcriber: Transcriber? = nil) -> CaptureController {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        return CaptureController(permission: permission, capture: capture, scheduler: scheduler, transcriber: transcriber)
    }

    private func makeRecording(transcriber: Transcriber? = nil) -> CaptureController {
        let controller = makeController(transcriber: transcriber)
        controller.start()
        permission.answer(true)
        return controller
    }

    // MARK: Permission and start

    func testCreatingControllerTouchesNeitherPermissionNorMicrophone() {
        let controller = makeController()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(permission.requests, 0)
        XCTAssertEqual(capture.starts, 0)
    }

    func testStartAsksPermissionBeforeOpeningMicrophone() {
        let controller = makeController()

        controller.start()

        XCTAssertEqual(controller.phase, .awaitingPermission)
        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(capture.starts, 0)
    }

    func testGrantedPermissionStartsRecording() {
        let controller = makeRecording()

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertTrue(capture.isRunning)
        XCTAssertNotNil(controller.sessionID)
    }

    func testRepeatedStartNeverOpensSecondCapture() {
        let controller = makeController()

        controller.start()
        controller.start()
        permission.answer(true)
        controller.start()

        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(controller.phase, .recording)
    }

    func testDeniedPermissionEndsSessionWithoutCapture() {
        let controller = makeController()

        controller.start()
        permission.answer(false)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.permissionDenied, duration: 0))
    }

    func testPermissionAnsweredAfterCancelIsIgnored() {
        let controller = makeController()

        controller.start()
        controller.cancel()
        permission.answer(true)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 0))
    }

    func testEachSessionHasItsOwnIdentifier() {
        let controller = makeRecording()
        let first = controller.sessionID
        controller.cancel()

        controller.start()
        permission.answer(true)

        XCTAssertNotNil(first)
        XCTAssertNotNil(controller.sessionID)
        XCTAssertNotEqual(controller.sessionID, first)
    }

    func testStateChangesAreNotified() {
        let controller = makeController()
        var phases: [CaptureController.Phase] = []
        controller.onChange = { phases.append(controller.phase) }

        controller.start()
        permission.answer(true)
        controller.cancel()

        XCTAssertEqual(phases, [.awaitingPermission, .recording, .idle])
    }

    // MARK: Stop and limits

    func testStopWithoutTranscriberReleasesMicrophoneAndReportsMeasuredDuration() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 2.0))

        controller.stop()

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Transcrição não configurada — áudio descartado (2,0 s)")
    }

    func testCaptureShorterThanMinimumIsDiscarded() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 0.4))

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.tooShort, duration: 0.4))
    }

    func testCaptureOfExactlyMinimumDurationIsKept() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 0.5))

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 0.5))
    }

    func testStopBeforeAnyAudioIsTooShort() {
        let controller = makeRecording()

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.tooShort, duration: 0))
    }

    func testSilentCaptureIsDiscarded() {
        let controller = makeRecording()
        capture.feed(Synthetic.silence(seconds: 2.0))

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.silent, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Silêncio — áudio descartado (2,0 s)")
    }

    func testFaintSignalBelowThresholdCountsAsSilence() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0, amplitude: 0.002))

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.silent, duration: 1.0))
    }

    func testRecordingStopsItselfAtMaximumDuration() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 29.9))

        scheduler.advance(by: 29.9)
        XCTAssertEqual(controller.phase, .recording)
        scheduler.advance(by: 0.1)

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 29.9))
    }

    func testAudioArrivingAfterStopIsIgnored() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))
        controller.stop()

        capture.feed(Synthetic.tone(seconds: 1.0))

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 1.0))
    }

    func testLateAudioOfEndedSessionDoesNotLeakIntoNextSession() {
        let controller = makeRecording()
        controller.cancel()
        capture.feed(Synthetic.tone(seconds: 1.0), start: 0)
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 1.0), start: 0)
        capture.feed(Synthetic.tone(seconds: 2.0))

        controller.stop()

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testMaximumTimerOfEndedSessionDoesNotStopNextSession() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))
        controller.stop()
        scheduler.advance(by: 10)

        controller.start()
        permission.answer(true)
        scheduler.advance(by: 20)

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(capture.isRunning)
        scheduler.advance(by: 10)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testStopOutsideRecordingIsIgnored() {
        let controller = makeController()
        controller.stop()
        XCTAssertNil(controller.lastOutcome)

        controller.start()
        controller.stop()

        XCTAssertEqual(controller.phase, .awaitingPermission)
    }

    // MARK: Interruptions

    func testCancelReleasesMicrophoneAndDiscardsAudio() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))

        controller.cancel()
        capture.feed(Synthetic.tone(seconds: 1.0))

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 1.0))
    }

    func testCancelWhenIdleKeepsLastOutcome() {
        let controller = makeRecording()
        controller.stop()

        controller.cancel()

        XCTAssertEqual(controller.lastOutcome, .discarded(.tooShort, duration: 0))
    }

    func testSuspensionEndsRecordingAndReleasesMicrophone() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))

        controller.suspend()

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.suspended, duration: 1.0))
    }

    func testSuspensionWhileAwaitingPermissionIgnoresLaterGrant() {
        let controller = makeController()
        controller.start()

        controller.suspend()
        permission.answer(true)

        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.suspended, duration: 0))
    }

    func testDeviceChangeEndsRecordingAndReleasesMicrophone() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))

        capture.fail(.deviceChanged)

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.capture(.deviceChanged), duration: 1.0))
    }

    func testSampleRateChangeMidSessionIsTreatedAsDeviceChange() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))

        capture.feed(Synthetic.tone(seconds: 0.1, rate: 44_100))

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.capture(.deviceChanged), duration: 1.0))
    }

    func testFailureReportedAfterSessionEndedIsIgnored() {
        let controller = makeRecording()
        capture.feed(Synthetic.tone(seconds: 1.0))
        controller.stop()

        capture.fail(.deviceChanged)

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 1.0))
    }

    func testMissingInputDeviceEndsSessionWithoutRecording() {
        let controller = makeController()
        capture.startError = .noInputDevice

        controller.start()
        permission.answer(true)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.capture(.noInputDevice), duration: 0))
        XCTAssertEqual(controller.lastOutcome?.message, "Nenhum microfone disponível")
    }

    // MARK: Transcriber contract (fake only; the app ships without a transcriber)

    private func makeProcessing(_ transcriber: FakeTranscriber, seconds: Double = 2.0) -> CaptureController {
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: seconds))
        controller.stop()
        return controller
    }

    func testTranscriberReceivesOnlyCurrentSessionAudio() {
        let transcriber = FakeTranscriber()
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 1.0))
        controller.cancel()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))

        controller.stop()

        XCTAssertEqual(controller.phase, .processing)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(transcriber.received.map(\.duration), [2.0])
    }

    func testTranscriptOfCurrentSessionIsReported() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.success("texto de teste sintético"))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .transcribed("texto de teste sintético", duration: 2.0))
    }

    func testDuplicateTranscriberResultIsIgnored() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.success("primeiro"))
        transcriber.complete(.success("duplicado"))

        XCTAssertEqual(controller.lastOutcome, .transcribed("primeiro", duration: 2.0))
    }

    func testProcessingDeadlineDiscardsAndIgnoresLateResult() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        scheduler.advance(by: 30)
        transcriber.complete(.success("atrasado"))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }

    func testDeadlineAfterDeliveredTranscriptIsIgnored() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.success("entregue"))
        scheduler.advance(by: 30)

        XCTAssertEqual(controller.lastOutcome, .transcribed("entregue", duration: 2.0))
    }

    func testCancelDuringProcessingIgnoresLaterResult() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        controller.cancel()
        transcriber.complete(.success("atrasado"))

        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testTranscriberFailureDiscardsAudio() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.failure(SyntheticError()))

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionFailed, duration: 2.0))
    }

    func testStartDuringProcessingIsIgnored() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        controller.start()

        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(permission.requests, 1)
    }
}
