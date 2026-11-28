import Foundation

/// Hands audio to the provider only after the user's explicit decisions, checked in this order:
/// consent for the destination, a key in memory for this run (saved or explicitly loaded in the
/// settings; the gate never consults the Keychain), and — for the first clip after consent — a
/// confirmation that names the clip. Consent and key are checked again after a "yes". Any refusal
/// fails without calling the provider.
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
    private let session: SessionAPIKey
    private let confirmFirstSend: FirstSendConfirmation
    /// Clips that may still be on their way; ended ones are dropped lazily.
    private var sends: [GatedSend] = []

    init(
        provider: Transcriber,
        consent: CloudConsent,
        session: SessionAPIKey,
        confirmFirstSend: @escaping FirstSendConfirmation
    ) {
        self.provider = provider
        self.consent = consent
        self.session = session
        self.confirmFirstSend = confirmFirstSend
    }

    public func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        if let refusal {
            completion(.failure(refusal))
            return .finished
        }
        let send = GatedSend(completion: completion)
        sends.removeAll { $0.isEnded }
        sends.append(send)
        if consent.state == .awaitingFirstSend { ask(audio, send) } else { send.start(audio, on: provider) }
        return TranscriptionCancellation { send.cancel() }
    }

    /// Stops every clip still on its way — question withdrawn, request cancelled — and reports
    /// `refusal` for it. For revoking consent and removing the key.
    func refuseAll(_ refusal: TranscriptionError) {
        let pending = sends
        sends = []
        for send in pending { send.end(.failure(refusal)) }
    }

    /// Why nothing may be sent now, if so: consent first, then this run's key.
    private var refusal: TranscriptionError? {
        if consent.state == .notGranted { return .consentRequired }
        return switch session.status {
        case .loaded: nil
        case .notLoaded: .credentialNotLoaded
        case .missing: .missingCredential
        case .unavailable: .credentialUnavailable
        }
    }

    private func ask(_ audio: CapturedAudio, _ send: GatedSend) {
        send.ask { [confirmFirstSend] in
            confirmFirstSend(audio.duration) { [weak self] accepted in
                guard let self, send.takeAnswer() else { return }
                guard accepted else { return send.end(.failure(TranscriptionError.declined)) }
                // Consent may have been revoked, or the key removed or reloaded, while the question
                // was open. Only a clip actually handed to the provider confirms the first send.
                if let refusal = self.refusal { return send.end(.failure(refusal)) }
                self.consent.confirmFirstSend()
                send.start(audio, on: self.provider)
            }
        }
    }
}

/// One clip on its way through the gate: question, if any, then provider. Ends once; after that,
/// answers and provider results are ignored.
@MainActor
private final class GatedSend {
    private enum Step { case checked, asking, sending, ended }

    private var step = Step.checked
    private let completion: @Sendable @MainActor (Result<String, Error>) -> Void
    private var question: TranscriptionCancellation?
    private var request: TranscriptionCancellation?
    private var providerAnswered = false

    init(completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void) {
        self.completion = completion
    }

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
        step = .checked
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

/// The app's only cloud path: OpenAI behind consent, this run's key and the first-send
/// confirmation, with the settings that load, save or remove the key and withdraw consent. Only the
/// settings touch the Keychain — on the keychain queue, on the user's explicit actions; the gate
/// and the provider use the key kept in memory for this run.
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
        compose(keys: keys, consent: consent, confirmFirstSend: confirmFirstSend, queue: queue) { credential in
            OpenAITranscriber(credential: credential, transport: transport)
        }
    }

    /// The composition `openAI` uses; `provider` builds the provider over this run's key.
    static func compose(
        keys: any APIKeyStore,
        consent: CloudConsent,
        confirmFirstSend: @escaping ConsentGatedTranscriber.FirstSendConfirmation,
        queue: KeychainQueue,
        provider makeProvider: (_ credential: @escaping @Sendable () async throws -> OpenAIAPIKey?) -> Transcriber
    ) -> CloudTranscription {
        let session = SessionAPIKey()
        let gate = ConsentGatedTranscriber(
            provider: makeProvider { @MainActor in session.key },
            consent: consent,
            session: session,
            confirmFirstSend: confirmFirstSend
        )
        return CloudTranscription(
            transcriber: gate,
            settings: CloudSettings(consent: consent, keys: keys, queue: queue, gate: gate, session: session)
        )
    }
}
