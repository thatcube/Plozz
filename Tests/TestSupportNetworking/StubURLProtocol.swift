import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One scripted HTTP response for ``StubURLProtocol``, plus optional request
/// assertions run at dispatch time so a test can assert exactly which
/// headers a request carried (e.g. `Accept-Encoding: identity`, `Range`,
/// `If-Match`, absence of `Authorization`) without a real server.
struct StubResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    /// Invoked with the exact `URLRequest` `StubURLProtocol` is about to
    /// answer. Use for header/method/redirect-chain assertions.
    let onRequest: (@Sendable (URLRequest) -> Void)?

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.onRequest = onRequest
    }
}

/// A scripted redirect: `StubURLProtocol` answers with a 3xx to `location`
/// instead of a terminal response.
struct StubRedirect {
    let statusCode: Int
    let location: URL
    let onRequest: (@Sendable (URLRequest) -> Void)?

    init(statusCode: Int = 302, location: URL, onRequest: (@Sendable (URLRequest) -> Void)? = nil) {
        self.statusCode = statusCode
        self.location = location
        self.onRequest = onRequest
    }
}

private enum StubbedOutcome {
    case response(StubResponse)
    case redirect(StubRedirect)
}

/// Deterministic, in-process `URLProtocol` stub used to test the transport
/// layer's request-building and response-handling logic without any real
/// network I/O — preferred over live-server tests per this module's testing
/// policy (controllable, non-flaky, offline).
///
/// Responses are queued per-URL (FIFO) so a test can script a probe then a
/// follow-up read against the same URL. `reset()` must run in `tearDown()`
/// between tests, since state is process-global (required by how
/// `URLProtocol.registerClass` works).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [URL: [StubbedOutcome]] = [:]
    nonisolated(unsafe) private static var requestLog: [URL: [URLRequest]] = [:]

    static func queue(_ response: StubResponse, for url: URL) {
        lock.lock(); queues[url, default: []].append(.response(response)); lock.unlock()
    }

    static func queue(redirect: StubRedirect, for url: URL) {
        lock.lock(); queues[url, default: []].append(.redirect(redirect)); lock.unlock()
    }

    static func requests(for url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requestLog[url, default: []]
    }

    static func reset() {
        lock.lock(); queues = [:]; requestLog = [:]; lock.unlock()
    }

    static func makeEphemeralSession() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.lock.lock()
        Self.requestLog[url, default: []].append(request)
        var queue = Self.queues[url] ?? []
        let outcome = queue.isEmpty ? nil : queue.removeFirst()
        Self.queues[url] = queue
        Self.lock.unlock()

        guard let outcome else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        switch outcome {
        case .response(let stub):
            stub.onRequest?(request)
            let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let redirect):
            redirect.onRequest?(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: redirect.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.location.absoluteString]
            )!
            var newRequest = request
            newRequest.url = redirect.location
            // Signal the redirect and stop there. The transport delegate
            // cancels the task itself when policy rejects the new origin.
            client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)
        }
    }

    override func stopLoading() {}
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
