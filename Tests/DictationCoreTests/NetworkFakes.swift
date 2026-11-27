@testable import DictationCore
import Foundation
import os
import XCTest

/// Placeholder credential for tests; not a real key.
let placeholderKey = OpenAIAPIKey("placeholder-key-for-tests")!

/// Records requests and answers through `reply`; never touches the network.
final class FakeTransport: HTTPTransport {
    private let log = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private let reply: @Sendable (URLRequest) async throws -> HTTPResponse
    let sent: XCTestExpectation

    init(reply: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.reply = reply
        sent = XCTestExpectation(description: "request handed to transport")
        sent.assertForOverFulfill = false
    }

    convenience init(status: Int, body: String) {
        self.init { _ in HTTPResponse(statusCode: status, body: Data(body.utf8)) }
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        sent.fulfill()
        return try await reply(request)
    }
}

/// One-shot latch that ignores task cancellation, like a transport that answers late anyway.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Serves every request of a session built from `configuration()` locally; nothing reaches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        /// Never answers, like a slow provider; only cancellation ends the request.
        case hang
        case respond(status: Int, body: Data)
        case redirect(to: URL)
    }

    struct Seen: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data
    }

    struct State: Sendable {
        var behavior: Behavior = .hang
        var seen: [Seen] = []
        var stops = 0
        var onStart: (@Sendable () -> Void)?
        var onStop: (@Sendable () -> Void)?
    }

    static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(_ behavior: Behavior) {
        state.withLock { $0 = State(behavior: behavior) }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let seen = Seen(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.drain(request.httpBodyStream)
        )
        let (behavior, onStart) = Self.state.withLock { state in
            state.seen.append(seen)
            return (state.behavior, state.onStart)
        }
        onStart?()
        guard let url = request.url, let client else { return }
        switch behavior {
        case .hang:
            break
        case let .respond(status, body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            var next = request
            next.url = target
            client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let onStop = Self.state.withLock { state in
            state.stops += 1
            return state.onStop
        }
        onStop?()
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
