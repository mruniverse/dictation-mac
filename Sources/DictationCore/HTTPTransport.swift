import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Sends one request. Cancelling the calling task must stop the request.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Ephemeral URLSession without cache, cookies or stored credentials. Redirects are refused, so the
/// Authorization header and the audio never follow a redirect. Cancelling the calling task cancels
/// the URLSession task.
public final class URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        return HTTPResponse(statusCode: http.statusCode, body: body)
    }
}

/// Delivers the 3xx response itself instead of following it.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
