@testable import DictationCore
import os
import Security
import XCTest

/// Consent, this run's key and the first-send confirmation in front of the provider, and the
/// settings that load, save, remove or withdraw them. Fakes only: no keychain, defaults, network
/// or microphone.
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
        // The app's composition, with the provider swapped for a fake.
        let cloud = CloudTranscription.compose(
            keys: keys, consent: consent, confirmFirstSend: confirmer.confirmation, queue: queue
        ) { _ in self.provider }
        settings = cloud.settings
        controller = CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: cloud.transcriber
        )
    }

    /// Records a synthetic clip and stops, handing it to the gate.
    private func recordAndStop(seconds: Double = 2.0) {
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: seconds))
        controller.stop()
    }

    /// The user's explicit "Carregar chave salva do Keychain"; the queue answers at once unless held.
    private func loadKey() {
        settings.loadKey { XCTAssertNil($0) }
    }

    private func grantAndLoadKey() {
        consent.grant()
        loadKey()
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

    func testALoadedKeyWithoutConsentSendsNothing() {
        loadKey()

        recordAndStop()

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testSavingAKeyNeverGrantsConsent() {
        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }

        XCTAssertEqual(consent.state, .notGranted)
        recordAndStop()
        XCTAssertTrue(provider.received.isEmpty)
    }

    // MARK: This run's key: the Keychain is read only on an explicit load, never by a clip

    func testConsentWithoutALoadedKeyNeverAsksSendsOrTouchesTheKeychain() {
        consent.grant()

        recordAndStop()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(keys.calls, [], "a saved key is neither looked up nor read unless the user loads it")
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
        XCTAssertEqual(
            controller.lastOutcome?.message, "Chave de API não carregada nesta execução — áudio descartado (2,0 s)"
        )
    }

    func testClipsReuseTheExplicitlyLoadedKeyWithoutTouchingTheKeychainAgain() {
        grantAndLoadKey()
        XCTAssertEqual(keys.calls, [.read])
        XCTAssertEqual(settings.keyStatus, .loaded)

        recordAndStop()
        confirmer.answer(true)
        provider.complete(.success("primeiro"))
        recordAndStop(seconds: 1.0)
        provider.complete(.success("segundo"), request: 1)

        XCTAssertEqual(provider.received.map(\.duration), [2.0, 1.0])
        XCTAssertEqual(controller.lastOutcome, .transcribed("segundo", duration: 1.0))
        XCTAssertEqual(keys.calls, [.read], "no lookup or read per clip, before or after the question")
    }

    func testLoadRunsOnTheKeychainQueueAndAClipStoppedMeanwhileDoesNotWaitForIt() {
        consent.grant()
        queue.holds = true

        loadKey()
        XCTAssertEqual(keys.calls, [], "the main path never touches the keychain")
        XCTAssertTrue(settings.isWaitingForKeychain)
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        recordAndStop()

        XCTAssertEqual(controller.phase, .idle, "a clip never waits on the keychain")
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
        queue.drain()
        XCTAssertEqual(keys.calls, [.read])
        XCTAssertFalse(settings.isWaitingForKeychain)
        XCTAssertEqual(settings.keyStatus, .loaded)
        recordAndStop(seconds: 1.0)
        XCTAssertEqual(confirmer.asked, [1.0])
    }

    func testLoadThatFindsNoSavedKeyDiscardsAsNotConfigured() throws {
        consent.grant()
        try keys.delete()

        loadKey()
        recordAndStop()

        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testRefusedLoadIsNotReportedAsAMissingKey() {
        consent.grant()
        keys.fail(.read, status: errSecInteractionNotAllowed)
        var failures: [KeychainError?] = []

        settings.loadKey { failures.append($0) }
        recordAndStop()

        XCTAssertEqual(failures, [KeychainError(status: errSecInteractionNotAllowed)])
        XCTAssertEqual(settings.keyStatus, .unavailable(KeychainError(status: errSecInteractionNotAllowed)))
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeychainUnavailable, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Keychain não liberou a chave de API — áudio descartado (2,0 s)")
    }

    // MARK: First-send confirmation

    func testFirstSendIsConfirmedWithClipDurationBeforeAnythingIsSent() {
        grantAndLoadKey()

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
        grantAndLoadKey()
        recordAndStop()
        confirmer.answer(true)
        provider.complete(.success("primeiro"))

        recordAndStop(seconds: 1.0)

        XCTAssertEqual(confirmer.asked, [2.0])
        XCTAssertEqual(provider.received.map(\.duration), [2.0, 1.0])
    }

    func testDeclinedFirstSendSendsNothingAndAsksAgainNextTime() {
        grantAndLoadKey()
        recordAndStop()

        confirmer.answer(false)

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionDeclined, duration: 2.0))
        XCTAssertEqual(controller.lastOutcome?.message, "Envio recusado — áudio descartado (2,0 s)")
        XCTAssertEqual(consent.state, .awaitingFirstSend)

        recordAndStop(seconds: 1.0)
        XCTAssertEqual(confirmer.asked, [2.0, 1.0])
        XCTAssertEqual(keys.calls, [.read])
    }

    func testRepeatedAnswerSendsOnce() {
        grantAndLoadKey()
        recordAndStop()

        confirmer.answer(true)
        confirmer.answer(true)

        XCTAssertEqual(provider.received.count, 1)
    }

    func testSynchronousConfirmationSendsOnce() {
        grantAndLoadKey()
        confirmer.immediateAnswer = true

        recordAndStop()

        XCTAssertEqual(provider.received.count, 1)
        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(confirmer.withdrawn, [], "an answered question has nothing to withdraw")
    }

    func testProviderAnswerIsReportedOnceAndItsRequestIsNotCancelled() {
        grantAndLoadKey()
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
        grantAndLoadKey()
        recordAndStop()

        controller.cancel()
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "a withdrawn question confirms nothing")
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(keys.calls, [.read])
    }

    func testDeadlineWhileConfirmingWithdrawsQuestionAndALateYesConfirmsNothing() {
        grantAndLoadKey()
        recordAndStop()

        scheduler.advance(by: 30)
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "a late yes must not activate consent")
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }

    func testRevocationWhileConfirmingBlocksTheSend() {
        grantAndLoadKey()
        recordAndStop()

        consent.revoke()
        confirmer.answer(true)

        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testReloadFindingNoKeyWhileConfirmingSendsAndConfirmsNothing() throws {
        grantAndLoadKey()
        recordAndStop()
        try keys.delete() // outside the app, e.g. in Keychain Access

        loadKey()
        confirmer.answer(true)

        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .awaitingFirstSend, "only a clip handed to the provider confirms the first send")
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testRefusedReloadWhileConfirmingKeepsTheKeyAlreadyLoaded() {
        grantAndLoadKey()
        recordAndStop()
        keys.fail(.read, status: errSecInteractionNotAllowed) // the keychain was locked again
        var failures: [KeychainError?] = []

        settings.loadKey { failures.append($0) }
        confirmer.answer(true)

        XCTAssertEqual(failures, [KeychainError(status: errSecInteractionNotAllowed)])
        XCTAssertEqual(settings.keyStatus, .loaded, "a failed reload changes nothing in memory")
        XCTAssertEqual(provider.received.count, 1)
        XCTAssertEqual(keys.calls, [.read, .read], "each read is an explicit load")
    }

    func testCancelAfterConfirmationCancelsTheProviderRequest() {
        grantAndLoadKey()
        recordAndStop()
        confirmer.answer(true)

        controller.cancel()
        controller.cancel()

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(confirmer.withdrawn, [])
    }

    func testCancelInsideProviderCallCancelsTheRequestItStarted() {
        grantAndLoadKey()
        recordAndStop()
        provider.duringTranscribe = { [controller] in controller!.cancel() }

        confirmer.answer(true)

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    // MARK: Settings: revoking consent and removing the key take effect at once

    func testRevokingWhileTheQuestionIsOpenWithdrawsItAndDiscardsTheClip() {
        grantAndLoadKey()
        recordAndStop()

        settings.revokeConsent()
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testRevokingCancelsTheRequestInFlightAndKeepsTheKey() {
        grantAndLoadKey()
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
        XCTAssertEqual(settings.keyStatus, .loaded, "nor forgets it for this run")
    }

    func testRevokingWhileRecordingSendsNothingWhenItStops() {
        grantAndLoadKey()
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))

        settings.revokeConsent()
        controller.stop()

        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testFailedRemovalWhileRecordingPreventsAnyUploadAndForgetsTheKey() {
        grantAndLoadKey()
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
        XCTAssertEqual(settings.keyStatus, .notLoaded, "removal forgets this run's key even if the delete fails")

        consent.grant()
        consent.confirmFirstSend()
        recordAndStop(seconds: 1.0)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 1.0))
    }

    func testFailedRemovalStillCancelsTheRequestInFlight() {
        grantAndLoadKey()
        consent.confirmFirstSend()
        keys.fail(.delete, status: errSecAuthFailed)
        recordAndStop()
        XCTAssertEqual(provider.received.count, 1)

        settings.removeKey { XCTAssertEqual($0, KeychainError(status: errSecAuthFailed)) }
        provider.complete(.success("tarde demais"))

        XCTAssertEqual(provider.cancelled, [0])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        XCTAssertEqual(consent.state, .notGranted)
    }

    func testRemovingTheKeyCancelsTheRequestInFlightAndRevokesConsent() {
        grantAndLoadKey()
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
        grantAndLoadKey()
        recordAndStop()

        settings.removeKey { XCTAssertNil($0) }
        confirmer.answer(true)

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testRemovalForgetsTheKeyBeforeTheKeychainAnswers() {
        grantAndLoadKey()
        queue.holds = true

        settings.removeKey { XCTAssertNil($0) }
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        consent.grant()
        consent.confirmFirstSend()
        recordAndStop()

        XCTAssertEqual(keys.calls, [.read], "the delete is still waiting on the queue")
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
        queue.drain()
        XCTAssertEqual(keys.calls, [.read, .delete])
        XCTAssertEqual(settings.keyStatus, .missing)
    }

    func testClipStoppedRightAfterRemovalDoesNotWaitForKeychain() {
        grantAndLoadKey()
        queue.holds = true

        settings.removeKey { XCTAssertNil($0) }
        recordAndStop()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(confirmer.asked.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
        queue.drain()
        XCTAssertEqual(keys.calls, [.read, .delete], "the clip itself never touches the keychain")
    }

    // MARK: Settings: a load or save asked before a removal never puts the key back

    func testRemovalFromPendingSaveNotificationDoesNotRecreateTheItem() {
        queue.holds = true
        settings.onChange = { [unowned self] in
            settings.onChange = nil
            settings.removeKey { XCTAssertNil($0) }
        }

        settings.saveKey(OpenAIAPIKey("synthetic-replacement-key")!) { _ in }
        queue.drain()

        XCTAssertEqual(keys.calls, [.save, .delete])
        XCTAssertNil(keys.storedKey, "a stale save must not recreate the deleted item")
        XCTAssertEqual(settings.keyStatus, .missing)
    }

    func testSaveFromRefusedClipRunsAfterTheRemovalItObserved() {
        grantAndLoadKey()
        recordAndStop()
        XCTAssertEqual(controller.phase, .processing)
        queue.holds = true
        let replacement = OpenAIAPIKey("synthetic-replacement-key")!
        controller.onChange = { [unowned self] in
            guard controller.phase == .idle else { return }
            controller.onChange = nil
            settings.saveKey(replacement) { XCTAssertNil($0) }
        }

        settings.removeKey { XCTAssertNil($0) }
        XCTAssertEqual(consent.state, .notGranted)
        XCTAssertTrue(provider.received.isEmpty)
        queue.drain()

        XCTAssertEqual(keys.calls, [.read, .delete, .save])
        XCTAssertTrue(keys.storedKey?.value == replacement.value, "the newest explicit save must win")
        XCTAssertEqual(settings.keyStatus, .loaded)
    }

    func testLoadAskedBeforeARemovalNeverPutsTheKeyBack() {
        consent.grant()
        queue.holds = true
        var loads: [KeychainError?] = []

        settings.loadKey { loads.append($0) }
        settings.removeKey { XCTAssertNil($0) }
        queue.drain()

        XCTAssertEqual(keys.calls, [.read, .delete])
        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertEqual(loads, [nil], "an overtaken load reports nothing")
        consent.grant()
        consent.confirmFirstSend()
        recordAndStop()
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
    }

    func testSaveAskedBeforeARemovalNeverPutsTheKeyBack() {
        queue.holds = true

        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }
        settings.removeKey { XCTAssertNil($0) }
        queue.drain()

        XCTAssertEqual(keys.calls, [.save, .delete])
        XCTAssertNil(keys.storedKey)
        XCTAssertEqual(settings.keyStatus, .missing)
        consent.grant()
        consent.confirmFirstSend()
        recordAndStop()
        XCTAssertTrue(provider.received.isEmpty)
    }

    func testLoadAskedBeforeAFailedRemovalStillDoesNotRestoreTheKey() {
        keys.fail(.delete, status: errSecAuthFailed)
        queue.holds = true

        loadKey()
        settings.removeKey { XCTAssertEqual($0, KeychainError(status: errSecAuthFailed)) }
        queue.drain()

        XCTAssertNotNil(keys.storedKey)
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        consent.grant()
        consent.confirmFirstSend()
        recordAndStop()
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
    }

    func testOvertakenFailuresAreNotReportedAfterARemoval() {
        keys.fail(.read, .save, status: errSecInteractionNotAllowed)
        queue.holds = true
        var failures: [KeychainError?] = []

        settings.loadKey { failures.append($0) }
        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { failures.append($0) }
        settings.removeKey { failures.append($0) }
        queue.drain()

        XCTAssertEqual(failures, [nil, nil, nil], "the menu is not told about operations the removal overtook")
        XCTAssertEqual(settings.keyStatus, .missing)
    }

    func testReloadQueuedWhileConfirmingIsOvertakenByARemoval() {
        grantAndLoadKey()
        recordAndStop()
        queue.holds = true

        loadKey()
        settings.removeKey { XCTAssertNil($0) }
        confirmer.answer(true)
        queue.drain()

        XCTAssertEqual(confirmer.withdrawn, [0])
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertEqual(keys.calls, [.read, .read, .delete])
    }

    func testLoadAskedAfterARemovalIsANewExplicitAction() {
        keys.fail(.delete, status: errSecAuthFailed)
        settings.removeKey { XCTAssertEqual($0, KeychainError(status: errSecAuthFailed)) }

        loadKey()

        XCTAssertEqual(settings.keyStatus, .loaded, "the item the delete could not remove is loaded on request")
        XCTAssertEqual(consent.state, .notGranted, "but sending needs consent again")
    }

    func testRevocationStopsLaterSendsAndRegrantAsksAgain() {
        grantAndLoadKey()
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

    func testKeyStatusStartsNotLoadedWithoutTouchingTheKeychain() {
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        XCTAssertFalse(settings.isWaitingForKeychain)
        settings.grantConsent()
        settings.revokeConsent()

        XCTAssertEqual(keys.calls, [])
    }

    func testKeyStatusTellsAMissingKeyFromAKeychainFailure() throws {
        var observed: [APIKeyStatus] = []
        settings.onChange = { observed.append(self.settings.keyStatus) }

        try keys.delete()
        loadKey()
        XCTAssertEqual(settings.keyStatus, .missing)
        XCTAssertEqual(observed.last, .missing, "the menu is told about the answer")

        keys.fail(.read, status: errSecInteractionNotAllowed)
        settings.loadKey { XCTAssertEqual($0, KeychainError(status: errSecInteractionNotAllowed)) }
        XCTAssertEqual(settings.keyStatus, .unavailable(KeychainError(status: errSecInteractionNotAllowed)))
        XCTAssertEqual(observed.last, .unavailable(KeychainError(status: errSecInteractionNotAllowed)))
    }

    func testWaitingForTheKeychainIsPublished() {
        var waiting: [Bool] = []
        settings.onChange = { waiting.append(self.settings.isWaitingForKeychain) }
        queue.holds = true

        loadKey()
        queue.drain()

        XCTAssertEqual(waiting, [true, false])
    }

    func testFailedSaveAndRemovalReportOnlyTheStatus() {
        loadKey()
        keys.fail(.save, .delete, status: errSecAuthFailed)
        var failures: [KeychainError?] = []

        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { failures.append($0) }
        XCTAssertEqual(settings.keyStatus, .loaded, "a failed save leaves the loaded key in place")
        settings.removeKey { failures.append($0) }

        XCTAssertEqual(failures, [KeychainError(status: errSecAuthFailed), KeychainError(status: errSecAuthFailed)])
        XCTAssertEqual(settings.keyStatus, .notLoaded)
        XCTAssertEqual(keys.storedKey?.value, "placeholder-key-for-tests", "the old key is still in the keychain")
    }

    func testSavedKeyIsKeptForThisRunWithoutReadingItBackOrTouchingConsent() {
        consent.grant()
        keys.fail(.read, status: errSecAuthFailed)

        settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }

        XCTAssertEqual(settings.keyStatus, .loaded)
        XCTAssertEqual(keys.storedKey?.value, "another-placeholder-key")
        XCTAssertEqual(consent.state, .awaitingFirstSend)
        recordAndStop()
        confirmer.answer(true)
        XCTAssertEqual(provider.received.count, 1)
        XCTAssertEqual(keys.calls, [.save], "settings never read the secret back")
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
        _ cloud: CloudTranscription, seconds: Double = 2.0
    ) -> (CaptureController, XCTestExpectation) {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        let controller = CaptureController(
            permission: permission, capture: capture, scheduler: scheduler, transcriber: cloud.transcriber
        )
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: seconds))
        let ended = expectation(description: "session ended")
        controller.onChange = { if controller.phase == .idle { ended.fulfill() } }
        controller.stop()
        return (controller, ended)
    }

    private func cloud(
        _ transport: FakeTransport,
        _ keys: any APIKeyStore,
        _ consent: CloudConsent,
        _ confirmer: FakeConfirmer = FakeConfirmer(),
        queue: KeychainQueue = ManualKeychainQueue()
    ) -> CloudTranscription {
        CloudTranscription.openAI(
            keys: keys, consent: consent, confirmFirstSend: confirmer.confirmation, queue: queue, transport: transport
        )
    }

    private func activeConsent() -> CloudConsent {
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        consent.confirmFirstSend()
        return consent
    }

    /// The app's own item, stored in a `SecItem` double; nothing touches the user's keychain.
    private func appKeychainItem() -> (FakeKeychain, KeychainAPIKeyStore) {
        let keychain = FakeKeychain()
        keychain.store([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAPIKeyStore.defaultService,
            kSecAttrAccount as String: "default",
            kSecValueData as String: Data("placeholder-key-for-tests".utf8),
        ])
        let store = KeychainAPIKeyStore(
            service: KeychainAPIKeyStore.defaultService, account: "default", keychain: keychain.functions
        )
        return (keychain, store)
    }

    private func hangingTransport(_ gate: Gate) -> FakeTransport {
        FakeTransport { _ in
            await gate.wait()
            return HTTPResponse(statusCode: 200, body: Data(#"{"text":"atrasado"}"#.utf8))
        }
    }

    // MARK: The real Keychain store over a SecItem double: count every operation

    func testAppCompositionReadsOnlyTheAppItemOnceOnAnExplicitLoadAndNeverPerClip() async throws {
        let (keychain, store) = appKeychainItem()
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let pipeline = cloud(transport, store, activeConsent())
        XCTAssertTrue(keychain.calls.isEmpty, "composing the cloud path touches nothing")

        let (notLoaded, discarded) = process(pipeline)
        await fulfillment(of: [discarded], timeout: 5)
        XCTAssertEqual(notLoaded.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
        XCTAssertTrue(keychain.calls.isEmpty, "recording and stopping never touch the keychain")
        XCTAssertTrue(transport.requests.isEmpty)

        pipeline.settings.loadKey { XCTAssertNil($0) }
        XCTAssertEqual(keychain.calls.map(\.operation), ["copy"])
        let query = try XCTUnwrap(keychain.calls.first?.query)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainAPIKeyStore.defaultService)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "default")
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(pipeline.settings.keyStatus, .loaded)

        for seconds in [2.0, 1.0] {
            let (controller, ended) = process(pipeline, seconds: seconds)
            await fulfillment(of: [ended], timeout: 5)
            XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: seconds))
        }

        XCTAssertEqual(keychain.calls.count, 1, "two clips sent, no further keychain call")
        XCTAssertEqual(transport.requests.count, 2)
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key-for-tests")
        }
    }

    func testDeniedThenAllowedLoadWithTheRealStoreCountsOneReadPerExplicitLoad() async {
        let (keychain, store) = appKeychainItem()
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let pipeline = cloud(transport, store, activeConsent())
        keychain.forcedStatus = errSecAuthFailed // the user denied the system's access dialog

        var failures: [KeychainError?] = []
        pipeline.settings.loadKey { failures.append($0) }
        let (denied, discarded) = process(pipeline)
        await fulfillment(of: [discarded], timeout: 5)

        XCTAssertEqual(failures, [KeychainError(status: errSecAuthFailed)])
        XCTAssertEqual(pipeline.settings.keyStatus, .unavailable(KeychainError(status: errSecAuthFailed)))
        XCTAssertEqual(denied.lastOutcome, .discarded(.transcriptionKeychainUnavailable, duration: 2.0))
        XCTAssertEqual(keychain.calls.count, 1, "a denied load is not retried by the clip")
        XCTAssertTrue(transport.requests.isEmpty)

        keychain.forcedStatus = nil
        pipeline.settings.loadKey { XCTAssertNil($0) }
        let (allowed, ended) = process(pipeline)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(allowed.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        XCTAssertEqual(keychain.calls.map(\.operation), ["copy", "copy"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDeclinedOrCancelledFirstSendWithTheRealStoreSendsNothingAndReadsNothingMore() async {
        let (keychain, store) = appKeychainItem()
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        let confirmer = FakeConfirmer()
        let pipeline = cloud(transport, store, consent, confirmer)
        pipeline.settings.loadKey { XCTAssertNil($0) }

        let (declined, first) = process(pipeline)
        confirmer.answer(false, question: 0)
        await fulfillment(of: [first], timeout: 5)
        let (cancelled, second) = process(pipeline)
        cancelled.cancel()
        confirmer.answer(true, question: 1)
        await fulfillment(of: [second], timeout: 5)

        XCTAssertEqual(declined.lastOutcome, .discarded(.transcriptionDeclined, duration: 2.0))
        XCTAssertEqual(cancelled.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(consent.state, .awaitingFirstSend)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(keychain.calls.count, 1)
    }

    func testRemovalWithTheRealStoreCancelsTheRequestAndALateAnswerIsIgnored() async {
        let (keychain, store) = appKeychainItem()
        let gate = Gate()
        let transport = hangingTransport(gate)
        let consent = activeConsent()
        let pipeline = cloud(transport, store, consent)
        pipeline.settings.loadKey { XCTAssertNil($0) }
        let (controller, ended) = process(pipeline)
        await fulfillment(of: [transport.sent], timeout: 5)

        pipeline.settings.removeKey { XCTAssertNil($0) }
        await fulfillment(of: [ended], timeout: 1)
        let changed = expectation(description: "no change after removal")
        changed.isInverted = true
        controller.onChange = { changed.fulfill() }
        await gate.open()
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertEqual(keychain.calls.map(\.operation), ["copy", "delete"])
        XCTAssertTrue(keychain.storedItems.isEmpty)
        XCTAssertEqual(pipeline.settings.keyStatus, .missing)

        consent.grant()
        consent.confirmFirstSend()
        let (after, discarded) = process(pipeline)
        await fulfillment(of: [discarded], timeout: 5)
        XCTAssertEqual(after.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(keychain.calls.count, 2)
    }

    func testLoadOvertakenByARemovalWithTheRealStoreNeverRestoresTheKey() async {
        let (keychain, store) = appKeychainItem()
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let consent = activeConsent()
        let queue = ManualKeychainQueue()
        queue.holds = true
        let pipeline = cloud(transport, store, consent, queue: queue)

        pipeline.settings.loadKey { XCTAssertNil($0) }
        pipeline.settings.removeKey { XCTAssertNil($0) }
        queue.drain()
        consent.grant()
        consent.confirmFirstSend()
        let (controller, ended) = process(pipeline)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(keychain.calls.map(\.operation), ["copy", "delete"])
        XCTAssertEqual(pipeline.settings.keyStatus, .missing)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTheLoadedKeyNeverShowsInDescriptionsOrDumps() {
        let (_, store) = appKeychainItem()
        let pipeline = cloud(FakeTransport(status: 200, body: "{}"), store, activeConsent())
        pipeline.settings.loadKey { XCTAssertNil($0) }
        XCTAssertEqual(pipeline.settings.keyStatus, .loaded)

        var rendered = String(describing: pipeline.settings.keyStatus) + String(reflecting: pipeline.settings)
        dump(pipeline.settings, to: &rendered)
        dump(pipeline.transcriber, to: &rendered)

        XCTAssertFalse(rendered.contains("placeholder-key-for-tests"))
    }

    // MARK: Fake key store

    func testAppPipelineSendsNothingWithoutConsent() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let keys = FakeKeyStore(placeholderKey)

        let (controller, ended) = process(cloud(transport, keys, CloudConsent(storage: MemoryConsentStorage())))
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(keys.calls, [])
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionNotAuthorized, duration: 2.0))
    }

    func testAppPipelineSendsOnceAfterConsentConfirmationAndAnExplicitLoad() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let consent = CloudConsent(storage: MemoryConsentStorage())
        consent.grant()
        let confirmer = FakeConfirmer()
        let pipeline = cloud(transport, keys, consent, confirmer)
        pipeline.settings.loadKey { XCTAssertNil($0) }

        let (controller, ended) = process(pipeline)
        XCTAssertTrue(transport.requests.isEmpty)
        confirmer.answer(true)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, OpenAITranscriber.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key-for-tests")
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        XCTAssertEqual(consent.state, .active)
        XCTAssertEqual(keys.calls, [.read])
    }

    func testSavedKeyIsTheOneSentWithoutReadingItBack() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore()
        let pipeline = cloud(transport, keys, activeConsent())

        pipeline.settings.saveKey(OpenAIAPIKey("another-placeholder-key")!) { XCTAssertNil($0) }
        let (_, ended) = process(pipeline)
        await fulfillment(of: [ended], timeout: 5)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer another-placeholder-key")
        XCTAssertEqual(keys.calls, [.save])
    }

    func testRevokingThroughTheAppSettingsCancelsTheRequestInFlight() async {
        let gate = Gate()
        let transport = hangingTransport(gate)
        let pipeline = cloud(transport, FakeKeyStore(placeholderKey), activeConsent())
        pipeline.settings.loadKey { XCTAssertNil($0) }
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

    func testAnExplicitLoadWaitsOnTheKeychainQueueButClipsNeverDo() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let queue = ManualKeychainQueue()
        queue.holds = true
        let pipeline = cloud(transport, keys, activeConsent(), queue: queue)

        pipeline.settings.loadKey { XCTAssertNil($0) }
        XCTAssertEqual(queue.pendingCount, 1)
        let (waiting, discarded) = process(pipeline)
        await fulfillment(of: [discarded], timeout: 5)
        XCTAssertEqual(waiting.lastOutcome, .discarded(.transcriptionKeyNotLoaded, duration: 2.0))
        XCTAssertEqual(queue.pendingCount, 1, "the clip added nothing to the keychain queue")

        queue.drain()
        let (controller, ended) = process(pipeline)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(keys.calls, [.read])
        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
    }

    func testDefaultCompositionTouchesTheKeychainOnlyOffTheMainThreadAndOnlyOnce() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#)
        let keys = FakeKeyStore(placeholderKey)
        let cloud = CloudTranscription.openAI(
            keys: keys, consent: activeConsent(), confirmFirstSend: FakeConfirmer().confirmation, transport: transport
        )

        let loaded = expectation(description: "key loaded")
        cloud.settings.loadKey { failure in
            XCTAssertNil(failure)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0..<2 {
            let (controller, ended) = process(cloud)
            XCTAssertEqual(controller.phase, .processing)
            await fulfillment(of: [ended], timeout: 5)
            XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
        }

        XCTAssertEqual(keys.calls, [.read])
        XCTAssertEqual(keys.callsOnMainThread, 0, "keychain calls may wait on a system dialog")
        XCTAssertEqual(transport.requests.count, 2)
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
