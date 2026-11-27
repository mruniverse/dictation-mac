import DictationCore
import XCTest

@MainActor
final class CaptureControllerTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!

    private func makeController(transcriber: Transcriber? = nil, limits: CaptureLimits = CaptureLimits()) -> CaptureController {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        return CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: transcriber, limits: limits
        )
    }

    private func makeRecording(transcriber: Transcriber? = nil, limits: CaptureLimits = CaptureLimits()) -> CaptureController {
        let controller = makeController(transcriber: transcriber, limits: limits)
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
        XCTAssertEqual(
            controller.lastOutcome?.message,
            "Silêncio — nenhum som captado; confira o microfone no menu Microfone (2,0 s)"
        )
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

    func testDisconnectedChosenMicrophoneEndsSessionWithoutFallingBack() {
        let controller = makeController()
        capture.startError = .selectedDeviceUnavailable

        controller.start()
        permission.answer(true)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(controller.lastOutcome, .discarded(.capture(.selectedDeviceUnavailable), duration: 0))
        XCTAssertEqual(
            controller.lastOutcome?.message,
            "Microfone escolhido não está conectado — escolha outro no menu Microfone"
        )
    }

    // MARK: Transcriber contract (fake transcriber; the app's cloud path is in CloudTranscriptionTests)

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

    // MARK: Request cancellation

    func testCancelDuringProcessingCancelsRequestOnce() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        controller.cancel()
        controller.cancel()

        XCTAssertEqual(transcriber.cancelled, [0])
    }

    func testDeadlineCancelsRequest() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        scheduler.advance(by: 30)

        XCTAssertEqual(transcriber.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }

    func testSuspensionDuringProcessingCancelsRequest() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        controller.suspend()

        XCTAssertEqual(transcriber.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.suspended, duration: 2.0))
    }

    func testDeliveredResultLeavesNothingToCancel() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.failure(SyntheticError()))
        controller.cancel()
        scheduler.advance(by: 30)

        XCTAssertEqual(transcriber.cancelled, [])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionFailed, duration: 2.0))
    }

    func testAnswerFromInsideCancelIsIgnored() {
        let transcriber = FakeTranscriber()
        transcriber.resultOnCancel = .success("durante o cancelamento")
        let controller = makeProcessing(transcriber)
        var notifications = 0
        controller.onChange = { notifications += 1 }

        controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testSynchronousAnswerIsReportedAndItsHandleIsNotKept() {
        let transcriber = FakeTranscriber()
        transcriber.immediateResult = .success("imediato")
        let controller = makeProcessing(transcriber)
        XCTAssertEqual(controller.lastOutcome, .transcribed("imediato", duration: 2.0))

        controller.start()
        permission.answer(true)
        controller.cancel()

        XCTAssertEqual(transcriber.cancelled, [], "a finished request must not be cancelled by a later session")
    }

    // MARK: Reentrancy (observers and schedulers that end the session inside stop/start)

    func testCancelFromProcessingNotificationSendsNothing() {
        let transcriber = FakeTranscriber()
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 2.0))
        controller.onChange = { if controller.phase == .processing { controller.cancel() } }
        let armed = scheduler.pendingTimers

        controller.stop()

        XCTAssertEqual(transcriber.received.count, 0, "audio of a cancelled session must never reach the transcriber")
        XCTAssertEqual(scheduler.pendingTimers, armed, "no processing deadline is armed for a session that already ended")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.sessionID)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        scheduler.advance(by: 30)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testNewSessionStartedFromProcessingNotificationKeepsItsOwnState() {
        let transcriber = FakeTranscriber()
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 2.0))
        var restarted = false
        controller.onChange = {
            guard controller.phase == .processing, !restarted else { return }
            restarted = true
            controller.cancel()
            controller.start()
        }

        controller.stop()

        XCTAssertEqual(transcriber.received.count, 0)
        XCTAssertEqual(controller.phase, .awaitingPermission, "stop() of the old session must not touch the new one")
        XCTAssertEqual(permission.requests, 2)
    }

    func testDeadlineFiringInsideScheduleSendsNothing() {
        var limits = CaptureLimits()
        limits.processingTimeout = 0
        let transcriber = FakeTranscriber()
        let controller = makeRecording(transcriber: transcriber, limits: limits)
        capture.feed(Synthetic.tone(seconds: 2.0))
        scheduler.firesDueTimersImmediately = true

        controller.stop()

        XCTAssertEqual(transcriber.received.count, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }

    func testSessionEndedInsideTranscribeCancelsTheOrphanedRequest() {
        let transcriber = FakeTranscriber()
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 2.0))
        transcriber.duringTranscribe = { controller.cancel() }

        controller.stop()

        XCTAssertEqual(transcriber.cancelled, [0], "the handle returned after the session ended must be cancelled")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testAnswerDeliveredAfterReentrantCancelInsideTranscribeIsIgnoredAndNotCancelled() {
        let transcriber = FakeTranscriber()
        transcriber.immediateResult = .success("depois do cancelamento")
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 2.0))
        transcriber.duringTranscribe = { controller.cancel() }

        controller.stop()

        XCTAssertEqual(transcriber.cancelled, [], "a request that already answered has nothing left to cancel")
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testSynchronousAnswerWhoseNotificationStartsNextSessionIsNotCancelled() {
        let transcriber = FakeTranscriber()
        transcriber.immediateResult = .success("imediato")
        let controller = makeRecording(transcriber: transcriber)
        capture.feed(Synthetic.tone(seconds: 2.0))
        var transcript: Outcome?
        controller.onChange = {
            guard controller.phase == .idle, transcript == nil else { return }
            transcript = controller.lastOutcome
            controller.start()
        }

        controller.stop()
        permission.answer(true)
        controller.cancel()

        XCTAssertEqual(transcript, .transcribed("imediato", duration: 2.0))
        XCTAssertEqual(transcriber.cancelled, [])
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 0))
    }

    func testCancelFromAwaitingPermissionNotificationNeverAsksPermission() {
        let controller = makeController()
        controller.onChange = { if controller.phase == .awaitingPermission { controller.cancel() } }

        controller.start()

        XCTAssertEqual(permission.requests, 0, "a cancelled session must not show the permission prompt")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 0))
    }

    // MARK: Transcript and provider errors

    func testBlankTranscriptIsNeverReportedAsText() {
        let transcriber = FakeTranscriber()
        let controller = makeProcessing(transcriber)

        transcriber.complete(.success(" \n\t"))

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionEmpty, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Nenhuma fala reconhecida — áudio descartado (2,0 s)")
    }

    func testProviderErrorsMapToTheirOwnReasons() {
        let cases: [(TranscriptionError, DiscardReason)] = [
            (.missingCredential, .transcriptionUnavailable),
            (.credentialUnavailable, .transcriptionKeychainUnavailable),
            (.unauthorized, .transcriptionUnauthorized),
            (.rateLimited, .transcriptionRateLimited),
            (.unsupportedAudio, .transcriptionFailed),
            (.rejected, .transcriptionFailed),
            (.server, .transcriptionFailed),
            (.network, .transcriptionFailed),
            (.invalidResponse, .transcriptionFailed),
        ]
        for (error, reason) in cases {
            let transcriber = FakeTranscriber()
            let controller = makeProcessing(transcriber)

            transcriber.complete(.failure(error))

            XCTAssertEqual(controller.lastOutcome, .discarded(reason, duration: 2.0), "\(error)")
        }
    }

    func testProviderErrorMessagesTellCredentialAndLimitApart() {
        XCTAssertEqual(
            Outcome.discarded(.transcriptionUnauthorized, duration: 1).message,
            "Chave de API recusada ou sem permissão — áudio descartado (1,0 s)"
        )
        XCTAssertEqual(
            Outcome.discarded(.transcriptionRateLimited, duration: 1).message,
            "Limite ou cota do provedor atingido — áudio descartado (1,0 s)"
        )
    }
}
