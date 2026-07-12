import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sequenced `HTTPClient` test double: matches by path suffix and can return a
/// different response each call (for polling scenarios).
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct StubbedResponse {
        var status: Int
        var json: String
        var headers: [String: String] = [:]
    }

    private var queues: [String: [StubbedResponse]] = [:]
    private var fixed: [(suffix: String, response: StubbedResponse)] = []
    private let lock = NSLock()
    private(set) var callCount = 0

    /// Adds a response that is returned every time `suffix` matches.
    func stubFixed(pathSuffix: String, json: String) {
        fixed.append((pathSuffix, StubbedResponse(status: 200, json: json)))
    }

    /// Adds a sequence of responses returned in order for `suffix`.
    func stubSequence(pathSuffix: String, jsons: [String]) {
        queues[pathSuffix, default: []].append(contentsOf: jsons.map {
            StubbedResponse(status: 200, json: $0)
        })
    }

    func stubSequence(pathSuffix: String, responses: [StubbedResponse]) {
        queues[pathSuffix, default: []].append(contentsOf: responses)
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await sendRaw(endpoint, baseURL: baseURL)
        switch result.1.statusCode {
        case 200...299:
            return result
        case 401, 403:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.invalidResponse
        }
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        func make(_ response: StubbedResponse) -> (Data, HTTPURLResponse) {
            (
                Data(response.json.utf8),
                HTTPURLResponse(
                    url: baseURL,
                    statusCode: response.status,
                    httpVersion: nil,
                    headerFields: response.headers
                )!
            )
        }
        if let key = queues.keys.first(where: { endpoint.path.hasSuffix($0) }), var q = queues[key], !q.isEmpty {
            let next = q.removeFirst()
            queues[key] = q
            return make(next)
        }
        if let match = fixed.first(where: { endpoint.path.hasSuffix($0.suffix) }) {
            return make(match.response)
        }
        throw AppError.notFound
    }
}
