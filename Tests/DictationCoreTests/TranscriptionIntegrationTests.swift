import DictationCore
import XCTest

/// CaptureController driving the real OpenAI adapter over fake or locally stubbed transports.
@MainActor
final class TranscriptionIntegrationTests: XCTestCase {
    private var permission: FakePermission!
    private var capture: FakeCapture!
    private var scheduler: FakeScheduler!

    /// Starts a 2 s synthetic session and stops it, leaving the request in flight.
    private func process(
        transport: HTTPTransport,
        credential: @escaping @Sendable () -> OpenAIAPIKey? = { placeholderKey }
    ) -> (CaptureController, XCTestExpectation) {
        permission = FakePermission()
        capture = FakeCapture()
        scheduler = FakeScheduler()
        let controller = CaptureController(
            permission: permission,
            capture: capture,
            scheduler: scheduler,
            transcriber: OpenAITranscriber(credential: credential, transport: transport)
        )
        controller.start()
        permission.answer(true)
        capture.feed(Synthetic.tone(seconds: 2.0))
        let ended = expectation(description: "session ended")
        controller.onChange = { if controller.phase == .idle { ended.fulfill() } }
        controller.stop()
        XCTAssertEqual(controller.phase, .processing)
        return (controller, ended)
    }

    func testTranscriptFromProviderEndsSession() async {
        let (controller, ended) = process(transport: FakeTransport(status: 200, body: #"{"text":"Ditado sintético."}"#))

        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(controller.lastOutcome, .transcribed("Ditado sintético.", duration: 2.0))
    }

    func testRefusedCredentialAndProviderLimitAreReportedApart() async {
        for (status, reason) in [(401, DiscardReason.transcriptionUnauthorized), (429, .transcriptionRateLimited)] {
            let (controller, ended) = process(transport: FakeTransport(status: status, body: #"{"error":{}}"#))

            await fulfillment(of: [ended], timeout: 5)

            XCTAssertEqual(controller.lastOutcome, .discarded(reason, duration: 2.0), "HTTP \(status)")
        }
    }

    func testMissingCredentialSendsNothing() async {
        let transport = FakeTransport(status: 200, body: #"{"text":"nunca"}"#)
        let (controller, ended) = process(transport: transport, credential: { nil })

        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionUnavailable, duration: 2.0))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLateAnswerAfterCancelNeverReplacesOutcome() async {
        let gate = Gate()
        let transport = FakeTransport { _ in
            await gate.wait()
            return HTTPResponse(statusCode: 200, body: Data(#"{"text":"atrasado"}"#.utf8))
        }
        let (controller, ended) = process(transport: transport)
        await fulfillment(of: [transport.sent], timeout: 5)

        controller.cancel()
        await fulfillment(of: [ended], timeout: 1)
        let changed = expectation(description: "no change after cancel")
        changed.isInverted = true
        controller.onChange = { changed.fulfill() }
        await gate.open()

        await fulfillment(of: [changed], timeout: 0.5)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
    }

    // MARK: Real URLSession, local URLProtocol

    private func processOverHangingSession() async -> (CaptureController, XCTestExpectation, XCTestExpectation) {
        StubURLProtocol.reset(.hang)
        let started = expectation(description: "request reached URLSession")
        let stopped = expectation(description: "URLSession task cancelled")
        StubURLProtocol.state.withLock { $0.onStart = { started.fulfill() }; $0.onStop = { stopped.fulfill() } }
        let (controller, ended) = process(transport: URLSessionTransport(configuration: StubURLProtocol.configuration()))
        await fulfillment(of: [started], timeout: 5)
        let seen = StubURLProtocol.state.withLock { $0.seen }
        XCTAssertEqual(seen.map(\.url), [OpenAITranscriber.endpoint])
        XCTAssertEqual(seen.first?.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary="), true)
        return (controller, ended, stopped)
    }

    func testCancelStopsTheURLSessionRequest() async {
        let (controller, ended, stopped) = await processOverHangingSession()

        controller.cancel()

        await fulfillment(of: [ended, stopped], timeout: 5)
        XCTAssertEqual(controller.lastOutcome, .discarded(.cancelled, duration: 2.0))
        XCTAssertEqual(StubURLProtocol.state.withLock { $0.stops }, 1)
    }

    func testDeadlineStopsTheURLSessionRequest() async {
        let (controller, ended, stopped) = await processOverHangingSession()

        scheduler.advance(by: 30)

        await fulfillment(of: [ended, stopped], timeout: 5)
        XCTAssertEqual(controller.lastOutcome, .discarded(.transcriptionTimedOut, duration: 2.0))
    }
}
