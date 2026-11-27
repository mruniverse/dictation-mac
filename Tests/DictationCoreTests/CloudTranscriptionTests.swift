@testable import DictationCore
import os
import Security
import XCTest

/// Consent, key and first-send confirmation in front of the provider, and the settings that
/// withdraw them. Fakes only: no keychain, defaults, network or microphone.
@MainActor
final class ConsentGateTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!
    private var storage: MemoryConsentStorage!
    private var consent: CloudConsent!
    private var keys: FakeKeyStore!
    private var queue: ManualKeychainQueue!
    private var confirmer: FakeConfirmer!
    private var provider: FakeTranscriber!
    private var settings: CloudSettings!
    private var controller: CaptureController!

    override func setUp() async throws {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        storage = MemoryConsentStorage()
        consent = CloudConsent(storage: storage)
        keys = FakeKeyStore(placeholderKey)
        queue = ManualKeychainQueue()
        confirmer = FakeConfirmer()
        provider = FakeTranscriber()
        let gate = ConsentGatedTranscriber(
            provider: provider, consent: consent, keys: keys, queue: queue, confirmFirstSend: confirmer.confirmation
        )
        settings = CloudSettings(consent: consent, keys: keys, queue: queue, gate: gate)
        controller = CaptureController(permission: permission, capture: capture, scheduler: scheduler, transcriber: gate)
    }

    /// Records a synthetic clip and stops, handing it to the gate.
    private func recordAndStop(seconds: Double = 2.0) {
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: seconds))
        controller.stop()
    }

    // MARK: Consent

    func testNothingIsSentWithoutConsent() {
        recordAndStop()

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertEqual(keys.calls, [], "without consent the key is not even looked up")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Envio à OpenAI não autorizado — áudio descartado (2,0 s)")
    }

    func testSavingAKeyNeverGrantsConsent() {
        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }

        XCTAssertEqual(consent.state, .notGranted)
        recordAndStop()
        XCTAssertTrue(provider.received.isEmpty)
    }

    func testConsentWithoutKeyNeverAsksOrSends() throws {
        consent.grant()
        try keys.delete()

        recordAndStop()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    // MARK: Keychain lookup (never on the main path, never mistaken for a missing key)

    func testKeyIsLookedUpOnTheKeychainQueueBeforeTheQuestion() {
        consent.grant()
        queue.holds = true

        recordAndStop()

        XCTAssertEqual(keys.calls, [], "the main path never touches the keychain")
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertEqual(controller.phase, .processing)
        queue.drain()
        XCTAssertEqual(keys.calls, [.contains], "attributes only; the secret is never read by the gate")
        XCTAssertEqual(confirmer.asked, [2.0])
    }

    func testKeychainFailureIsNotReportedAsAMissingKey() {
        consent.grant()
        keys.fail(.contains, status: errSecInteractionNotAllowed)

        recordAndStop()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeychainUnavailable, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Keychain não liberou a chave de API — áudio descartado (2,0 s)")
    }

    func testCancelDuringTheKeyLookupNeverAsks() {
        consent.grant()
        queue.holds = true
        recordAndStop()

        controller.cancel()
        queue.drain()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    // MARK: First-send confirmation

    func testFirstSendIsConfirmedWithClipDurationBeforeAnythingIsSent() {
        consent.grant()

        recordAndStop()

        XCTAssertEqual(confirmer.asked, [2.0])
        XCTAssertTrue(provider.received.isEmpty, "nothing leaves before the user confirms")
        XCTAssertEqual(controller.phase, .processing)

        confirmer.answer(true)

        XCTAssertEqual(provider.received.map(\.duration), [2.0])
        XCTAssertEqual(consent.state, .active)
        provider.complete(.success("texto sintético"))
        XCTAssertEqual(controller.lastOutcome, .transcribed("texto sintético", duration: 2.0))
    }

    func testLaterClipsAreSentWithoutAskingAgain() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)
        provider.complete(.success("primeiro"))

        recordAndStop(seconds: 1.0)

        XCTAssertEqual(confirmer.asked, [2.0])
        XCTAssertEqual(provider.received.map(\.duration), [2.0, 1.0])
    }

    func testDeclinedFirstSendSendsNothingAndAsksAgainNextTime() {
        consent.grant()
        recordAndStop()

        confirmer.answer(false)

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionDeclined, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Envio recusado — áudio descartado (2,0 s)")
        XCTAssertEqual(consent.state, .awaitingFirstSend)

        recordAndStop(seconds: 1.0)
        XCTAssertEqual(confirmer.asked, [2.0, 1.0])
    }

    func testRepeatedAnswerSendsOnce() {
        consent.grant()
        recordAndStop()

        confirmer.answer(true)
        confirmer.answer(true)

        XCTAssertEqual(provider.received.count, 1)
    }

    func testSynchronousConfirmationSendsOnce() {
        consent.grant()
        confirmer.immediateAnswer = true

        recordAndStop()

        XCTAssertEqual(provider.received.count, 1)
        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(confirmer.withdrawn, [], "an answered question has nothing to withdraw")
    }

    func testProviderAnswerIsReportedOnceAndItsRequestIsNotCancelled() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)

        provider.complete(.success("uma vez"))
        provider.complete(.success("de novo"))
        controller.cancel()

        XCTAssertEqual(controller.lastOutcome, .transcribed("uma vez", duration: 2.0))
        XCTAssertEqual(provider.cancelled, [])
    }

    // MARK: Late answers (the question is withdrawn on time; a later "yes" counts for nothing)

    func testCancelWhileConfirmingWithdrawsQuestionAndIgnoresLaterYes() {
        consent.grant()
        recordAndStop()

        controller.cancel()
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "a withdrawn question confirms nothing")
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    func testDeadlineWhileConfirmingWithdrawsQuestionAndALateYesConfirmsNothing() {
        consent.grant()
        recordAndStop()

        scheduler.advance(by: 30)
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "a late yes must not activate consent")
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }

    func testYesThenCancelBeforeTheKeyIsLookedUpAgainSendsAndConfirmsNothing() {
        consent.grant()
        recordAndStop()
        queue.holds = true

        confirmer.answer(true)
        controller.cancel()
        queue.drain()

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "only a clip handed to the provider confirms the first send")
    }

    func testRevocationWhileConfirmingBlocksTheSend() {
        consent.grant()
        recordAndStop()

        consent.revoke()
        confirmer.answer(true)

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testKeyRemovedElsewhereWhileConfirmingBlocksTheSend() throws {
        consent.grant()
        recordAndStop()

        try keys.delete()
        confirmer.answer(true)

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testCancelAfterConfirmationCancelsTheProviderRequest() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)

        controller.cancel()
        controller.cancel()

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(confirmer.withdrawn, [])
    }

    func testCancelInsideProviderCallCancelsTheRequestItStarted() {
        consent.grant()
        recordAndStop()
        provider.duringTranscribe = { [controller] in controller!.cancel() }

        confirmer.answer(true)

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    // MARK: Settings: revoking consent and removing the key take effect at once

    func testRevokingWhileTheQuestionIsOpenWithdrawsItAndDiscardsTheClip() {
        consent.grant()
        recordAndStop()

        settings.revokeConsent()
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testRevokingCancelsTheRequestInFlightAndKeepsTheKey() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)
        provider.resultOnCancel = .failure(TranscriptionError.cancelled)

        settings.revokeConsent()
        provider.complete(.success("tarde demais"))

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertNotNil(keys.storedKey, "revoking never deletes the key")
    }

    func testRevokingDuringTheKeyLookupDiscardsTheClip() {
        consent.grant()
        queue.holds = true
        recordAndStop()

        settings.revokeConsent()
        queue.drain()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testRevokingWhileRecordingSendsNothingWhenItStops() {
        consent.grant()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))

        settings.revokeConsent()
        controller.stop()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testFailedRemovalWhileRecordingPreventsAnyUploadForThatClip() {
        consent.grant()
        consent.confirmFirstSend()
        keys.fail(.delete, status: errSecAuthFailed)
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))

        settings.removeKey { XCTAssertEqual($0, KeychainError(status: errSecAuthFailed)) }
        controller.stop()

        XCTAssertNotNil(keys.storedKey, "the system failed to delete the credential")
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testRemovingTheKeyCancelsTheRequestInFlightAndRevokesConsent() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)

        settings.removeKey { XCTAssertNil($0) }
        provider.complete(.success("tarde demais"))

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertNil(keys.storedKey)
        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertEqual(consent.state, .notGranted)
    }

    func testRemovingTheKeyWhileTheQuestionIsOpenWithdrawsIt() {
        consent.grant()
        recordAndStop()

        settings.removeKey { XCTAssertNil($0) }
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testClipStoppedRightAfterRemovalDoesNotWaitForKeychain() {
        consent.grant()
        queue.holds = true

        settings.removeKey { XCTAssertNil($0) }
        recordAndStop()
        queue.drain()

        XCTAssertEqual(keys.calls, [.delete, .contains], "the clip must not look up a key after consent is revoked")
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testRevocationStopsLaterSendsAndRegrantAsksAgain() {
        consent.grant()
        recordAndStop()
        confirmer.answer(true)
        provider.complete(.success("enviado"))

        settings.revokeConsent()
        recordAndStop(seconds: 1.0)

        XCTAssertEqual(provider.received.count, 1)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 1.0))

        settings.grantConsent()
        recordAndStop(seconds: 1.5)
        XCTAssertEqual(confirmer.asked, [2.0, 1.5], "first-send confirmation is required again")
        XCTAssertEqual(provider.received.count, 1)
    }

    // MARK: Settings: key status

    func testKeyStatusIsUnknownUntilTheLookupAnswersOffTheMainPath() {
        queue.holds = true

        settings.refreshKeyStatus()

        XCTAssertEqual(settings.keyStatus, .unknown)
        XCTAssertEqual(keys.calls, [])
        queue.drain()
        XCTAssertEqual(settings.keyStatus, .stored)
    }

    func testKeyStatusTellsAMissingKeyFromAKeychainFailure() throws {
        var changes = 0
        settings.onChange = { changes += 1 }

        try keys.delete()
        settings.refreshKeyStatus()
        XCTAssertEqual(settings.keyStatus, .missing)

        keys.fail(.contains, status: errSecInteractionNotAllowed)
        settings.refreshKeyStatus()
        XCTAssertEqual(settings.keyStatus, .unavailable(KeychainError(status: errSecInteractionNotAllowed)))
        XCTAssertEqual(changes, 2)
    }

    func testFailedSaveAndRemovalReportOnlyTheStatusAndRefreshIt() {
        keys.fail(.save, .delete, status: errSecAuthFailed)
        var failures: [KeychainError?] = []

        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { failures.append($0) }
        settings.removeKey { failures.append($0) }

        XCTAssertEqual(failures, [KeychainError(status: errSecAuthFailed), KeychainError(status: errSecAuthFailed)])
        XCTAssertEqual(settings.keyStatus, .stored, "the old key is still there")
        XCTAssertEqual(keys.storedKey?.value, "placeholder-key-for-tests")
    }

    func testSavedKeyIsReportedStoredWithoutTouchingConsent() {
        consent.grant()
        keys.fail(.read, status: errSecAuthFailed)

        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }

        XCTAssertEqual(settings.keyStatus, .stored)
        XCTAssertEqual(keys.storedKey?.value, "another-placeholder-key")
        XCTAssertEqual(consent.state, .awaitingFirstSend)
        XCTAssertFalse(keys.calls.contains(.read), "settings never read the secret")
    }
}

@MainActor
final class CloudConsentTests: XCTestCase {
    func testStartsNotGrantedAndPersistsEachStep() {
        let storage = MemoryConsentStorage()
        XCTAssertEqual(CloudConsent(storage: storage).state, .notGranted)

        CloudConsent(storage: storage).grant()
        XCTAssertEqual(CloudConsent(storage: storage).state, .awaitingFirstSend)

        CloudConsent(storage: storage).confirmFirstSend()
        XCTAssertEqual(CloudConsent(storage: storage).state, .active)

        CloudConsent(storage: storage).revoke()
        XCTAssertEqual(CloudConsent(storage: storage).state, .notGranted)
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testConfirmationWithoutGrantIsIgnored() {
        let consent = CloudConsent(storage: MemoryConsentStorage())

        consent.confirmFirstSend()

        XCTAssertEqual(consent.state, .notGranted)
    }

    func testGrantingAgainKeepsConfirmation() {
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()

        consent.grant()

        XCTAssertEqual(consent.state, .active)
    }

    func testConsentIsBoundToItsDestination() {
        let storage = MemoryConsentStorage()
        CloudConsent(storage: storage, destination: "https://example.invalid/v1 other-model").grant()

        XCTAssertEqual(CloudConsent(storage: storage).state, .notGranted)
        XCTAssertEqual(
            OpenAITranscriber.destination,
            "https://api.openai.com/v1/audio/transcriptions gpt-transcribe"
        )
    }

    func testRecordNamesDestinationAndHoldsNoSecret() {
        let storage = MemoryConsentStorage()
        let consent = CloudConsent(storage: storage)
        consent.grant()
        consent.confirmFirstSend()

        XCTAssertEqual(storage.values.count, 1)
        let record = storage.values.values.joined()
        XCTAssertTrue(record.contains("api.openai.com"))
        XCTAssertFalse(record.contains("placeholder-key-for-tests"))
    }
}

/// The composition the app uses (`CloudTranscription.openAI`) over a fake transport.
@MainActor
final class CloudPipelineTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!

    private func process(
        _ cloud: CloudTranscription
    ) -> (CaptureController, XCTestExpectation) {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        let controller = CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: cloud.transcriber
        )
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        let ended = expectation(description: "session ended")
        controller.onChange = { if controller.phase == .idle { ended.fulfill() } }
        controller.stop()
        return (controller, ended)
    }

    private func cloud(
        _ transport: FakeTransport,
        _ keys: FakeKeyStore,
        _ consent: CloudConsent,
        _ confirmer: FakeConfirmer = FakeConfirmer(),
        queue: KeychainQueue = ManualKeychainQueue()
    ) -> CloudTranscription {
        CloudTranscription.openAI(
            keys: keys, consent: consent, confirmFirstSend: confirmer.confirmation, queue: queue, transport: transport
        )
    }

    func testAppPipelineSendsNothingWithoutConsent() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let keys = FakeKeyStore(placeholderKey)

        let (controller, ended) = process(cloud(transport, keys, CloudConsent(storage: MemoryConsentStorage())))
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(keys.calls, [])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testAppPipelineDeclinedFirstSendSendsNothing() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let keys = FakeKeyStore(placeholderKey)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        let confirmer = FakeConfirmer()

        let (controller, ended) = process(cloud(transport, keys, consent, confirmer))
        confirmer.answer(false)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(keys.reads, 0)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionDeclined, duration: 2.0))
    }

    func testAppPipelineSendsOnceAfterConsentAndConfirmationWithStoredKey() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        let confirmer = FakeConfirmer()

        let (controller, ended) = process(cloud(transport, keys, consent, confirmer))
        XCTAssertTrue(transport.requests.isEmpty)
        confirmer.answer(true)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, OpenAITranscriber.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key-for-tests")
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        XCTAssertEqual(consent.state, .active)
    }

    func testUnreadableKeyIsReportedAsKeychainFailureAndNothingIsSent() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let keys = FakeKeyStore(placeholderKey)
        keys.fail(.read, status: errSecAuthFailed)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()

        let (controller, ended) = process(cloud(transport, keys, consent))
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeychainUnavailable, duration: 2.0))
    }

    func testRevokingThroughTheAppSettingsCancelsTheRequestInFlight() async {
        let gate = Gate()
        let transport = FakeTransport { _ in
            await gate.wait()
            return HTTPResponse(statusCode: 200, body: Data(#"{"text":"atrasado"}"#.utf8))
        }
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()
        let pipeline = cloud(transport, FakeKeyStore(placeholderKey), consent)
        let (controller, ended) = process(pipeline)
        await fulfillment(of: [transport.sent], timeout: 5)

        pipeline.settings.revokeConsent()
        await fulfillment(of: [ended], timeout: 1)
        let changed = expectation(description: "no change after revocation")
        changed.isInverted = true
        controller.onChange = { changed.fulfill() }
        await gate.open()

        await fulfillment(of: [changed], timeout: 0.5)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testTheSecretIsReadThroughTheKeychainQueue() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()
        let queue = ManualKeychainQueue()
        queue.holds = true

        let (controller, ended) = process(cloud(transport, keys, consent, queue: queue))
        queue.drain()
        for _ in 0..<200 where queue.pendingCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(queue.pendingCount, 1, "the provider waits for its read on the queue")
        XCTAssertEqual(keys.calls, [.contains])
        XCTAssertTrue(transport.requests.isEmpty)
        queue.drain()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(keys.calls, [.contains, .read])
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
    }

    func testDefaultCompositionTouchesTheKeychainOnlyOffTheMainThread() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()
        let cloud = CloudTranscription.openAI(
            keys: keys, consent: consent, confirmFirstSend: FakeConfirmer().confirmation, transport: transport
        )

        let (controller, ended) = process(cloud)
        XCTAssertEqual(controller.phase, .processing)
        await fulfillment(of: [ended], timeout: 5)
        let refreshed = expectation(description: "key status published")
        cloud.settings.onChange = { refreshed.fulfill() }
        cloud.settings.refreshKeyStatus()
        await fulfillment(of: [refreshed], timeout: 5)

        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        XCTAssertEqual(keys.calls, [.contains, .read, .contains])
        XCTAssertEqual(keys.callsOnMainThread, 0, "keychain calls may wait on a system dialog")
        XCTAssertEqual(cloud.settings.keyStatus, .stored)
    }
}

final class SerialKeychainQueueTests: XCTestCase {
    func testWorkRunsOffTheMainThreadOneAtATimeInOrderAndDeliversOnMain() async throws {
        let queue = SerialKeychainQueue()
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let release = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "both delivered")
        delivered.expectedFulfillmentCount = 2

        queue.run({
            log.withLock { $0.append("A starts, main=\(Thread.isMainThread)") }
            // Like a keychain call waiting on a system dialog. Bounded, so a queue that runs work
            // on the caller's (main) thread fails here instead of deadlocking the suite.
            _ = release.wait(timeout: .now() + 2)
            log.withLock { $0.append("A ends") }
            return "A"
        }) { value in
            log.withLock { $0.append("\(value) delivered, main=\(Thread.isMainThread)") }
            delivered.fulfill()
        }
        queue.run({
            log.withLock { $0.append("B starts, main=\(Thread.isMainThread)") }
            return "B"
        }) { value in
            log.withLock { $0.append("\(value) delivered, main=\(Thread.isMainThread)") }
            delivered.fulfill()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.withLock { $0 }, ["A starts, main=false"], "B waits while A is blocked")

        release.signal()
        await fulfillment(of: [delivered], timeout: 5)

        let entries = log.withLock { $0 }
        XCTAssertEqual(entries.filter { !$0.contains("delivered") }, ["A starts, main=false", "A ends", "B starts, main=false"])
        XCTAssertEqual(entries.filter { $0.contains("delivered") }, ["A delivered, main=true", "B delivered, main=true"])
    }
}
