import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configurable `HTTPClient` test double matching by path suffix.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub { var status: Int = 200; var body: Data }

    var responses: [(suffix: String, stub: Stub)] = []
    var error: AppError?
    /// Guards the request-recording arrays below: the provider now issues several
    /// row requests **concurrently** (library-scoped Continue Watching/Latest fan
    /// out per library), so two `send(_:)` calls can race on these without a lock.
    private let lock = NSLock()
    private(set) var sentPaths: [String] = []
    private(set) var sentMethods: [HTTPMethod] = []
    private(set) var sentBodies: [String: Data] = [:]
    private(set) var sentQueryItems: [[URLQueryItem]] = []

    func stub(pathSuffix: String, json: String, status: Int = 200) {
        responses.append((pathSuffix, Stub(status: status, body: Data(json.utf8))))
    }

    /// All query items sent for the most recent request whose path ends in `suffix`.
    func queryItems(forPathSuffix suffix: String) -> [URLQueryItem]? {
        lock.lock()
        defer { lock.unlock() }
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentQueryItems[index]
        }
        return nil
    }

    /// The HTTP method of the most recent request whose path ends in `suffix`.
    func method(forPathSuffix suffix: String) -> HTTPMethod? {
        lock.lock()
        defer { lock.unlock() }
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentMethods[index]
        }
        return nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sentPaths.append(endpoint.path)
        sentMethods.append(endpoint.method)
        if let body = endpoint.body { sentBodies[endpoint.path] = body }
        sentQueryItems.append(endpoint.queryItems)
        lock.unlock()
        if let error { throw error }
        guard let match = responses.first(where: { endpoint.path.hasSuffix($0.suffix) })?.stub else {
            throw AppError.notFound
        }
        switch match.status {
        case 200...299:
            return (match.body, HTTPURLResponse(url: baseURL, statusCode: match.status, httpVersion: nil, headerFields: nil)!)
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        default: throw AppError.invalidResponse
        }
    }
}
