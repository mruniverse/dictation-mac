import Foundation

/// The user's own OpenAI API key. String conversion, debug output and reflection are redacted.
public struct OpenAIAPIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    /// Trims surrounding whitespace; rejects empty input and anything outside visible ASCII,
    /// which would also corrupt the Authorization header.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return nil
        }
        value = trimmed
    }

    public var description: String { "OpenAIAPIKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Transcribes one finished clip with `gpt-transcribe` at OpenAI's official endpoint, both fixed.
/// One request per clip: no streaming, retry, fallback or model switch. Audio stays in memory and
/// nothing is logged. Errors are reduced to `TranscriptionError`.
@MainActor
public final class OpenAITranscriber: Transcriber {
    nonisolated public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    nonisolated public static let model = "gpt-transcribe"
    /// What the user's consent names: changing the endpoint or the model requires a new consent.
    nonisolated public static let destination = endpoint.absoluteString + " " + model
    /// Provider limit per file is 25 MB; 30 s of 48 kHz 16-bit mono is about 2.9 MB.
    static let maxFileBytes = 25_000_000

    private let credential: @Sendable () async throws -> OpenAIAPIKey?
    private let transport: HTTPTransport
    private let makeBoundary: @Sendable () -> String
    private let maxFileBytes: Int

    /// `credential` is read for each clip, before encoding. `nil` is `missingCredential`; a thrown
    /// keychain failure is `credentialUnavailable`. Either way nothing is sent.
    public convenience init(
        credential: @escaping @Sendable () async throws -> OpenAIAPIKey?,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.init(
            credential: credential,
            transport: transport,
            makeBoundary: { "dictation-mac-" + UUID().uuidString },
            maxFileBytes: Self.maxFileBytes
        )
    }

    init(
        credential: @escaping @Sendable () async throws -> OpenAIAPIKey?,
        transport: HTTPTransport,
        makeBoundary: @escaping @Sendable () -> String,
        maxFileBytes: Int
    ) {
        self.credential = credential
        self.transport = transport
        self.makeBoundary = makeBoundary
        self.maxFileBytes = maxFileBytes
    }

    public func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        let job = Job(
            audio: audio,
            credential: credential,
            transport: transport,
            makeBoundary: makeBoundary,
            maxFileBytes: maxFileBytes
        )
        let task = Task { @MainActor in
            let result: Result<String, Error>
            do {
                result = .success(try await job.run())
            } catch {
                result = .failure(TranscriptionError(sanitizing: error))
            }
            // Same actor as cancel(): once cancelled, nothing is reported, even if the transport answered.
            guard !Task.isCancelled else { return }
            completion(result)
        }
        return TranscriptionCancellation { task.cancel() }
    }

    /// Encoding and network run off the main actor.
    private struct Job: Sendable {
        let audio: CapturedAudio
        let credential: @Sendable () async throws -> OpenAIAPIKey?
        let transport: HTTPTransport
        let makeBoundary: @Sendable () -> String
        let maxFileBytes: Int

        func run() async throws -> String {
            try Task.checkCancellation()
            let stored: OpenAIAPIKey?
            do {
                stored = try await credential()
            } catch {
                throw TranscriptionError.credentialUnavailable
            }
            guard let key = stored else { throw TranscriptionError.missingCredential }
            let wav = try WAVEncoder.encode(audio)
            guard wav.count <= maxFileBytes else { throw TranscriptionError.unsupportedAudio }
            let delimiter = try boundary(avoiding: wav)
            let request = OpenAITranscriber.request(wav: wav, key: key, boundary: delimiter)
            try Task.checkCancellation()
            return try OpenAITranscriber.transcript(from: await transport.send(request))
        }

        /// RFC 2046: the delimiter must not occur inside the part.
        private func boundary(avoiding wav: Data) throws -> String {
            for _ in 0..<4 {
                let candidate = makeBoundary()
                if wav.range(of: Data(candidate.utf8)) == nil { return candidate }
            }
            throw TranscriptionError.unsupportedAudio
        }
    }

    nonisolated static func request(wav: Data, key: OpenAIAPIKey, boundary: String) -> URLRequest {
        var body = Data(capacity: wav.count + 512)
        func line(_ text: String) { body.append(contentsOf: Array((text + "\r\n").utf8)) }
        line("--" + boundary)
        line("Content-Disposition: form-data; name=\"model\"")
        line("")
        line(model)
        line("--" + boundary)
        line("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"")
        line("Content-Type: audio/wav")
        line("")
        body.append(wav)
        line("")
        line("--" + boundary + "--")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key.value, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// Only `text` is read; provider error bodies are never parsed, kept or surfaced.
    nonisolated static func transcript(from response: HTTPResponse) throws -> String {
        switch response.statusCode {
        case 200..<300:
            guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
                throw TranscriptionError.invalidResponse
            }
            return payload.text
        case 401, 403: throw TranscriptionError.unauthorized
        case 429: throw TranscriptionError.rateLimited
        case 400..<500: throw TranscriptionError.rejected
        case 500..<600: throw TranscriptionError.server
        default: throw TranscriptionError.invalidResponse
        }
    }

    private struct Payload: Decodable {
        let text: String
    }
}

extension TranscriptionError {
    /// Drops every detail of foreign errors (URLs, messages, user info).
    init(sanitizing error: Error) {
        switch error {
        case let known as TranscriptionError: self = known
        case is CancellationError: self = .cancelled
        case let url as URLError where url.code == .cancelled: self = .cancelled
        default: self = .network
        }
    }
}
