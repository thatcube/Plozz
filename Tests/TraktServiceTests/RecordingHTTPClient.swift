import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Recording `HTTPClient` test double. Matches stubbed responses by path suffix
/// and captures the requests it sent (path, decoded JSON body, headers) so tests
/// can assert on Trakt's payloads and the sequence of polled requests.
final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Sent {
        let path: String
        let headers: [String: String]
        let body: Data?
        var json: [String: Any]? {
            guard let body else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Stub { var status: Int; var body: Data }

    /// Per-suffix queues of responses. Each call pops the next response, falling
    /// back to the last one once the queue is drained — handy for "fail N times
    /// then succeed" polling scenarios.
    private var responses: [String: [Stub]] = [:]
    var error: AppError?
    private(set) var sent: [Sent] = []
    private let lock = NSLock()

    func stub(pathSuffix: String, json: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        responses[pathSuffix, default: []].append(Stub(status: status, body: Data(json.utf8)))
    }

    /// Convenience for an empty 200 (scrobble / revoke responses we ignore).
    func stubEmpty(pathSuffix: String, status: Int = 201) {
        stub(pathSuffix: pathSuffix, json: "{}", status: status)
    }

    var sentPaths: [String] { lock.lock(); defer { lock.unlock() }; return sent.map(\.path) }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sent.append(Sent(path: endpoint.path, headers: endpoint.headers, body: endpoint.body))
        if let error { lock.unlock(); throw error }
        let match = responses.first { endpoint.path.hasSuffix($0.key) }?.value
        let stub: Stub
        if var queue = match, !queue.isEmpty {
            stub = queue.count > 1 ? queue.removeFirst() : queue[0]
            if let key = responses.first(where: { endpoint.path.hasSuffix($0.key) })?.key {
                responses[key] = queue
            }
        } else {
            lock.unlock()
            throw AppError.notFound
        }
        lock.unlock()

        switch stub.status {
        case 200...299:
            return (stub.body, HTTPURLResponse(url: baseURL, statusCode: stub.status, httpVersion: nil, headerFields: nil)!)
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        case 409: throw AppError.conflict
        default: throw AppError.invalidResponse
        }
    }
}
