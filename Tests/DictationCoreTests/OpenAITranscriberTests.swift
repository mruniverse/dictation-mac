@testable import DictationCore
import AVFoundation
import os
import Security
import XCTest

final class WAVEncoderTests: XCTestCase {
    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func int16(_ data: Data, sample index: Int) -> Int16 {
        Int16(bitPattern: uint16(data, 44 + 2 * index))
    }

    func testHeaderDescribesMonoSixteenBitPCMAtCapturedRate() throws {
        let wav = try WAVEncoder.encode(CapturedAudio(samples: [Float](repeating: 0, count: 480), sampleRate: 48_000))

        XCTAssertEqual(wav.count, 44 + 960)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(uint32(wav, 4), UInt32(36 + 960))
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(uint32(wav, 16), 16)
        XCTAssertEqual(uint16(wav, 20), 1, "linear PCM")
        XCTAssertEqual(uint16(wav, 22), 1, "mono")
        XCTAssertEqual(uint32(wav, 24), 48_000)
        XCTAssertEqual(uint32(wav, 28), 96_000, "byte rate")
        XCTAssertEqual(uint16(wav, 32), 2, "block align")
        XCTAssertEqual(uint16(wav, 34), 16, "bits per sample")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(uint32(wav, 40), 960)
    }

    func testSamplesAreScaledClampedAndNaNBecomesSilence() throws {
        let samples: [Float] = [0, 1, -1, 0.5, 2, -3, .nan, .infinity, -.infinity]
        let wav = try WAVEncoder.encode(CapturedAudio(samples: samples, sampleRate: 16_000))

        XCTAssertEqual(
            (0..<samples.count).map { int16(wav, sample: $0) },
            [0, 32767, -32767, 16384, 32767, -32767, 0, 32767, -32767]
        )
    }

    func testInvalidSampleRateIsRejectedBeforeAnyUpload() {
        for rate in [0, -48_000, .nan, .infinity, 0.4] as [Double] {
            XCTAssertThrowsError(try WAVEncoder.encode(CapturedAudio(samples: [0.1], sampleRate: rate))) {
                XCTAssertEqual($0 as? TranscriptionError, .unsupportedAudio, "rate \(rate)")
            }
        }
    }

    func testEmptyAudioIsRejectedBeforeAnyUpload() {
        XCTAssertThrowsError(try WAVEncoder.encode(CapturedAudio(samples: [], sampleRate: 48_000))) {
            XCTAssertEqual($0 as? TranscriptionError, .unsupportedAudio)
        }
    }

    /// Apple's own decoder must accept the file; written only to a temporary path and removed.
    func testCoreAudioReadsBackTheSyntheticTone() throws {
        let audio = CapturedAudio(samples: Synthetic.tone(seconds: 0.5).flatMap(\.samples), sampleRate: Synthetic.rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try WAVEncoder.encode(audio).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(audio.samples.count))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let worst = zip(decoded, audio.samples).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(worst, 1.0 / 32_767 + 1e-6)
    }
}

@MainActor
final class OpenAITranscriberTests: XCTestCase {
    private let audio = CapturedAudio(samples: Synthetic.tone(seconds: 1.0).flatMap(\.samples), sampleRate: Synthetic.rate)
    private let leakingBody = #"{"error":{"message":"Incorrect API key provided: placeholder-key-for-tests (secret-detail)"}}"#

    private func run(
        _ transcriber: OpenAITranscriber,
        _ audio: CapturedAudio? = nil
    ) async -> Result<String, Error> {
        let done = expectation(description: "completion")
        let box = OSAllocatedUnfairLock<Result<String, Error>?>(uncheckedState: nil)
        _ = transcriber.transcribe(audio ?? self.audio) { result in
            box.withLockUnchecked { $0 = result }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        return box.withLockUnchecked { $0 } ?? .failure(TranscriptionError.invalidResponse)
    }

    private func failure(of result: Result<String, Error>) -> Error? {
        if case let .failure(error) = result { return error }
        XCTFail("expected failure, got \(result)")
        return nil
    }

    private func assertNoLeak(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = [
            String(describing: error), String(reflecting: error),
            error.localizedDescription, "\((error as NSError).userInfo)",
        ].joined(separator: "\n")
        for secret in ["placeholder-key-for-tests", "secret-detail", "Incorrect API key"] {
            XCTAssertFalse(rendered.contains(secret), "error exposes \(secret)", file: file, line: line)
        }
    }

    // MARK: Request

    func testRequestIsMultipartWithFixedModelAndInMemoryWAVAtOfficialEndpoint() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"Você pode revisar o relatório?","languages":[{"code":"pt"}]}"#)
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: transport)

        let result = await run(transcriber)

        XCTAssertEqual(try result.get(), "Você pode revisar o relatório?")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key-for-tests")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)

        var expected = Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
            + "gpt-transcribe\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        ).utf8)
        expected.append(try WAVEncoder.encode(audio))
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(request.httpBody, expected, "only model and file; no prompt, language or extra fields")
        XCTAssertNil(request.httpBodyStream)
    }

    func testBoundaryNeverOccursInsideTheAudio() async throws {
        let candidates = OSAllocatedUnfairLock(initialState: ["RIFF", "dictation-mac-unique"])
        let transport = FakeTransport(status: 200, body: #"{"text":"ok"}"#)
        let transcriber = OpenAITranscriber(
            credential: { placeholderKey },
            transport: transport,
            makeBoundary: { candidates.withLock { $0.removeFirst() } },
            maxFileBytes: OpenAITranscriber.maxFileBytes
        )

        _ = await run(transcriber)

        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=dictation-mac-unique"
        )
    }

    func testMissingCredentialSendsNothing() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let transcriber = OpenAITranscriber(credential: { nil }, transport: transport)

        let error = failure(of: await run(transcriber))

        XCTAssertEqual(error as? TranscriptionError, .missingCredential)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnreadableCredentialIsNotAMissingKeyAndSendsNothing() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let transcriber = OpenAITranscriber(
            credential: { throw KeychainError(status: errSecInteractionNotAllowed) }, transport: transport
        )

        let result = await run(transcriber)
        let error = try XCTUnwrap(failure(of: result))

        XCTAssertEqual(error as? TranscriptionError, .credentialUnavailable)
        XCTAssertTrue(transport.requests.isEmpty)
        assertNoLeak(error)
    }

    func testAudioAboveUploadLimitIsNotSent() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let transcriber = OpenAITranscriber(
            credential: { placeholderKey }, transport: transport, makeBoundary: { "b" }, maxFileBytes: 1_000
        )

        let error = failure(of: await run(transcriber, CapturedAudio(samples: [Float](repeating: 0.1, count: 500), sampleRate: 16_000)))

        XCTAssertEqual(error as? TranscriptionError, .unsupportedAudio)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testProviderLimitStaysAboveLongestCapture() throws {
        let longest = CapturedAudio(samples: [Float](repeating: 0.1, count: 30 * 48_000), sampleRate: 48_000)
        XCTAssertLessThan(try WAVEncoder.encode(longest).count, OpenAITranscriber.maxFileBytes)
    }

    func testEmptyAudioIsNotSent() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: transport)

        let error = failure(of: await run(transcriber, CapturedAudio(samples: [], sampleRate: 48_000)))

        XCTAssertEqual(error as? TranscriptionError, .unsupportedAudio)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Credential

    func testAPIKeyRejectsEmptyOrHeaderBreakingInput() {
        for raw in ["", "   \n", "two words", "key\r\nX-Injected: 1", "chave-ç", "tab\tkey"] {
            XCTAssertNil(OpenAIAPIKey(raw), "accepted \(raw.debugDescription)")
        }
        XCTAssertEqual(OpenAIAPIKey("  placeholder-key-for-tests\n")?.value, "placeholder-key-for-tests")
    }

    func testAPIKeyIsRedactedInDescriptionsAndReflection() {
        var dumped = ""
        dump(placeholderKey, to: &dumped)
        let rendered = ["\(placeholderKey)", String(reflecting: placeholderKey), dumped].joined(separator: "\n")

        XCTAssertFalse(rendered.contains("placeholder-key-for-tests"))
        XCTAssertTrue(rendered.contains("redacted"))
    }

    // MARK: Response and errors

    func testStatusCodesMapToPayloadFreeErrors() {
        let cases: [(Int, TranscriptionError)] = [
            (401, .unauthorized), (403, .unauthorized), (429, .rateLimited),
            (400, .rejected), (413, .rejected), (415, .rejected),
            (500, .server), (503, .server), (307, .invalidResponse), (101, .invalidResponse),
        ]
        for (status, expected) in cases {
            XCTAssertThrowsError(
                try OpenAITranscriber.transcript(from: HTTPResponse(statusCode: status, body: Data(leakingBody.utf8)))
            ) {
                XCTAssertEqual($0 as? TranscriptionError, expected, "HTTP \(status)")
                assertNoLeak($0)
            }
        }
    }

    func testMalformedSuccessBodyIsInvalidResponse() {
        for body in ["", "not json", #"{"languages":[]}"#, #"{"text":3}"#, #"["text"]"#] {
            XCTAssertThrowsError(try OpenAITranscriber.transcript(from: HTTPResponse(statusCode: 200, body: Data(body.utf8)))) {
                XCTAssertEqual($0 as? TranscriptionError, .invalidResponse, body)
            }
        }
    }

    func testProviderTextIsReturnedVerbatim() throws {
        let body = #"{"text":"  Isso é uma pergunta? Sim!\n","languages":[]}"#
        XCTAssertEqual(
            try OpenAITranscriber.transcript(from: HTTPResponse(statusCode: 200, body: Data(body.utf8))),
            "  Isso é uma pergunta? Sim!\n"
        )
    }

    func testRefusedCredentialSurfacesWithoutProviderMessage() async throws {
        let transport = FakeTransport(status: 401, body: leakingBody)
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: transport)

        let result = await run(transcriber)
        let error = try XCTUnwrap(failure(of: result))

        XCTAssertEqual(error as? TranscriptionError, .unauthorized)
        assertNoLeak(error)
    }

    func testTransportErrorsAreReducedToPayloadFreeCases() async throws {
        let offline = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://api.openai.com/?secret-detail",
            NSLocalizedDescriptionKey: "secret-detail",
        ])
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: FakeTransport { _ in throw offline })

        let result = await run(transcriber)
        let error = try XCTUnwrap(failure(of: result))

        XCTAssertEqual(error as? TranscriptionError, .network)
        assertNoLeak(error)
        XCTAssertEqual(TranscriptionError(sanitizing: SyntheticError()), .network)
        XCTAssertEqual(TranscriptionError(sanitizing: URLError(.timedOut)), .network)
        XCTAssertEqual(TranscriptionError(sanitizing: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(TranscriptionError(sanitizing: CancellationError()), .cancelled)
        XCTAssertEqual(TranscriptionError(sanitizing: TranscriptionError.rateLimited), .rateLimited)
    }

    // MARK: Cancellation

    func testCancelBeforeTheTaskRunsSendsNothingAndNeverCompletes() async throws {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: transport)
        let completed = expectation(description: "no completion")
        completed.isInverted = true

        let request = transcriber.transcribe(audio) { _ in completed.fulfill() }
        request.cancel()

        await fulfillment(of: [completed], timeout: 0.5)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnswerArrivingAfterCancelIsNeverReported() async throws {
        let gate = Gate()
        let transport = FakeTransport { _ in
            await gate.wait()
            return HTTPResponse(statusCode: 200, body: Data(#"{"text":"atrasado"}"#.utf8))
        }
        let transcriber = OpenAITranscriber(credential: { placeholderKey }, transport: transport)
        let completed = expectation(description: "no completion")
        completed.isInverted = true

        let request = transcriber.transcribe(audio) { _ in completed.fulfill() }
        await fulfillment(of: [transport.sent], timeout: 5)
        request.cancel()
        request.cancel()
        await gate.open()

        await fulfillment(of: [completed], timeout: 0.5)
        XCTAssertEqual(transport.requests.count, 1)
    }
}

/// Real URLSession over a local URLProtocol: proves cancellation and hardening without network.
final class URLSessionTransportTests: XCTestCase {
    private var request: URLRequest {
        var request = URLRequest(url: OpenAITranscriber.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data("corpo".utf8)
        request.setValue("Bearer placeholder-key-for-tests", forHTTPHeaderField: "Authorization")
        return request
    }

    func testReturnsStatusAndBodyAndSendsHeadersAndBodyUnchanged() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: Data(#"{"text":"ok"}"#.utf8)))
        let transport = URLSessionTransport(configuration: StubURLProtocol.configuration())

        let response = try await transport.send(request)

        XCTAssertEqual(response, HTTPResponse(statusCode: 200, body: Data(#"{"text":"ok"}"#.utf8)))
        let seen = try XCTUnwrap(StubURLProtocol.state.withLock { $0.seen }.first)
        XCTAssertEqual(seen.url, OpenAITranscriber.endpoint)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer placeholder-key-for-tests")
        XCTAssertEqual(seen.body, Data("corpo".utf8))
    }

    func testCancellingTheCallingTaskCancelsTheURLSessionTask() async throws {
        StubURLProtocol.reset(.hang)
        let started = expectation(description: "loading started")
        let stopped = expectation(description: "loading stopped")
        StubURLProtocol.state.withLock { $0.onStart = { started.fulfill() }; $0.onStop = { stopped.fulfill() } }
        let transport = URLSessionTransport(configuration: StubURLProtocol.configuration())
        let request = request

        let task = Task { try await transport.send(request) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 5)

        let result = await task.result
        guard case let .failure(error) = result else { return XCTFail("expected cancellation, got \(result)") }
        XCTAssertEqual(TranscriptionError(sanitizing: error), .cancelled)
    }

    func testRedirectIsNotFollowed() async throws {
        StubURLProtocol.reset(.redirect(to: URL(string: "https://example.invalid/collect")!))
        let transport = URLSessionTransport(configuration: StubURLProtocol.configuration())

        let response = try await transport.send(request)

        XCTAssertEqual(response.statusCode, 307)
        XCTAssertEqual(StubURLProtocol.state.withLock { $0.seen.map(\.url) }, [OpenAITranscriber.endpoint])
        XCTAssertThrowsError(try OpenAITranscriber.transcript(from: response)) {
            XCTAssertEqual($0 as? TranscriptionError, .invalidResponse)
        }
    }

    func testSessionKeepsNoCacheCookiesOrStoredCredentials() {
        let configuration = URLSessionTransport(configuration: StubURLProtocol.configuration()).session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}
