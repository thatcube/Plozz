import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sequenced `HTTPClient` test double: matches by path suffix and can return a
/// different response each call (for polling scenarios).
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private var queues: [String: [Data]] = [:]
    private var fixed: [(suffix: String, data: Data)] = []
    private let lock = NSLock()
    private(set) var callCount = 0

    /// Adds a response that is returned every time `suffix` matches.
    func stubFixed(pathSuffix: String, json: String) {
        fixed.append((pathSuffix, Data(json.utf8)))
    }

    /// Adds a sequence of responses returned in order for `suffix`.
    func stubSequence(pathSuffix: String, jsons: [String]) {
        queues[pathSuffix, default: []].append(contentsOf: jsons.map { Data($0.utf8) })
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        func ok(_ data: Data) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if let key = queues.keys.first(where: { endpoint.path.hasSuffix($0) }), var q = queues[key], !q.isEmpty {
            let next = q.removeFirst()
            queues[key] = q
            return ok(next)
        }
        if let match = fixed.first(where: { endpoint.path.hasSuffix($0.suffix) }) {
            return ok(match.data)
        }
        throw AppError.notFound
    }
}
