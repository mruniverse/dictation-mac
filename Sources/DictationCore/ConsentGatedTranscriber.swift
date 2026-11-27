import Foundation

/// Hands audio to the provider only after the user's explicit decisions, checked in this order:
/// consent for the destination, a stored API key (looked up on the keychain queue, attributes
/// only), and — for the first clip after consent — a confirmation that names the clip. Consent and
/// key are checked again after a "yes". Any refusal fails without calling the provider.
@MainActor
public final class ConsentGatedTranscriber: Transcriber {
    /// Asks the user to confirm the first upload of a clip lasting `duration` seconds, without
    /// blocking the main thread. `reply` is honoured once; after the returned handle withdraws the
    /// question, any reply is ignored.
    public typealias FirstSendConfirmation = @MainActor (
        _ duration: TimeInterval,
        _ reply: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> TranscriptionCancellation

    private let provider: Transcriber
    private let consent: CloudConsent
    private let keys: any APIKeyStore
    private let queue: KeychainQueue
    private let confirmFirstSend: FirstSendConfirmation
    /// Clips that may still be on their way; ended ones are dropped lazily.
    private var sends: [GatedSend] = []

    init(
        provider: Transcriber,
        consent: CloudConsent,
        keys: any APIKeyStore,
        queue: KeychainQueue,
        confirmFirstSend: @escaping FirstSendConfirmation
    ) {
        self.provider = provider
        self.consent = consent
        self.keys = keys
        self.queue = queue
        self.confirmFirstSend = confirmFirstSend
    }

    public func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        guard consent.state != .notGranted else {
            completion(.failure(TranscriptionError.consentRequired))
            return .finished
        }
        let send = GatedSend(completion: completion)
        sends.removeAll { $0.isEnded }
        sends.append(send)
        whenAllowed(send) { [weak self] in self?.askOrSend(audio, send) }
        return TranscriptionCancellation { send.cancel() }
    }

    /// Stops every clip still on its way — question withdrawn, key lookup ignored, request
    /// cancelled — and reports `refusal` for it. For revoking consent and removing the key.
    func refuseAll(_ refusal: TranscriptionError) {
        let pending = sends
        sends = []
        for send in pending { send.end(.failure(refusal)) }
    }

    /// Looks the key up on the keychain queue, then goes on only if the clip still waits for that
    /// answer and consent still holds.
    private func whenAllowed(_ send: GatedSend, then next: @escaping @MainActor () -> Void) {
        queue.run({ [keys] in Result { try keys.contains() } }) { [weak self] lookup in
            guard let self, send.isLookingUpKey else { return }
            if let refusal = self.refusal(after: lookup) { return send.end(.failure(refusal)) }
            next()
        }
    }

    private func refusal(after lookup: Result<Bool, Error>) -> TranscriptionError? {
        if consent.state == .notGranted { return .consentRequired }
        return switch lookup {
        case .success(true): nil
        case .success(false): .missingCredential
        case .failure: .credentialUnavailable
        }
    }

    private func askOrSend(_ audio: CapturedAudio, _ send: GatedSend) {
        guard consent.state == .awaitingFirstSend else { return send.start(audio, on: provider) }
        send.ask { [confirmFirstSend] in
            confirmFirstSend(audio.duration) { [weak self] accepted in
                guard let self, send.takeAnswer() else { return }
                guard accepted else { return send.end(.failure(TranscriptionError.declined)) }
                // Consent may have been revoked, or the key removed, while the question was open.
                // Only a clip actually handed to the provider confirms the first send.
                self.whenAllowed(send) {
                    self.consent.confirmFirstSend()
                    send.start(audio, on: self.provider)
                }
            }
        }
    }
}

/// One clip on its way through the gate: key lookup, question, key lookup again, provider. Ends
/// once; after that, lookups, answers and provider results are ignored.
@MainActor
private final class GatedSend {
    private enum Step { case lookingUpKey, asking, sending, ended }

    private var step = Step.lookingUpKey
    private let completion: @Sendable @MainActor (Result<String, Error>) -> Void
    private var question: TranscriptionCancellation?
    private var request: TranscriptionCancellation?
    private var providerAnswered = false

    init(completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    var isLookingUpKey: Bool { step == .lookingUpKey }
    var isEnded: Bool { step == .ended }

    func ask(_ open: () -> TranscriptionCancellation) {
        step = .asking
        let handle = open()
        // An answer given inside `open` already moved on; that question has nothing to withdraw.
        if step == .asking { question = handle }
    }

    /// Accepts the first answer to the open question; later answers, or any after withdrawal, are ignored.
    func takeAnswer() -> Bool {
        guard step == .asking else { return false }
        step = .lookingUpKey
        question = nil
        return true
    }

    func start(_ audio: CapturedAudio, on provider: Transcriber) {
        step = .sending
        let handle = provider.transcribe(audio) { [self] result in
            providerAnswered = true
            request = nil
            end(result)
        }
        if step == .sending {
            request = handle
        } else if !providerAnswered {
            // Ended inside `transcribe` without its result: nothing else owns this request.
            handle.cancel()
        }
    }

    /// The session ended: withdraw the question or cancel the request, and report nothing.
    func cancel() { close() }

    func end(_ result: Result<String, Error>) {
        guard close() else { return }
        completion(result)
    }

    @discardableResult
    private func close() -> Bool {
        guard step != .ended else { return false }
        step = .ended
        let (question, request) = (self.question, self.request)
        self.question = nil
        self.request = nil
        question?.cancel()
        request?.cancel()
        return true
    }
}

/// The app's only cloud path: OpenAI behind consent, a stored key and the first-send confirmation,
/// with the settings that withdraw them. Gate, settings and provider share one keychain queue, so a
/// lookup or read asked after a removal sees the removal.
@MainActor
public struct CloudTranscription {
    public let transcriber: Transcriber
    public let settings: CloudSettings

    public static func openAI(
        keys: any APIKeyStore,
        consent: CloudConsent,
        confirmFirstSend: @escaping ConsentGatedTranscriber.FirstSendConfirmation,
        queue: KeychainQueue = SerialKeychainQueue(),
        transport: HTTPTransport = URLSessionTransport()
    ) -> CloudTranscription {
        let provider = OpenAITranscriber(
            credential: { @MainActor in try await queue.value { Result { try keys.read() } }.get() },
            transport: transport
        )
        let gate = ConsentGatedTranscriber(
            provider: provider, consent: consent, keys: keys, queue: queue, confirmFirstSend: confirmFirstSend
        )
        return CloudTranscription(
            transcriber: gate,
            settings: CloudSettings(consent: consent, keys: keys, queue: queue, gate: gate)
        )
    }
}
