import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configurable `HTTPClient` test double matching by path suffix, mirroring the
/// ProviderJellyfin test stub.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub { var status: Int = 200; var body: Data }

    var responses: [(suffix: String, stub: Stub)] = []
    private var queues: [String: [Data]] = [:]
    var error: AppError?
    private(set) var sentPaths: [String] = []
    private(set) var sentMethods: [HTTPMethod] = []
    private(set) var sentQueryItems: [[URLQueryItem]] = []

    func stub(pathSuffix: String, json: String, status: Int = 200) {
        responses.append((pathSuffix, Stub(status: status, body: Data(json.utf8))))
    }

    /// Adds a sequence of responses returned in order for `suffix` (for polling).
    func stubSequence(pathSuffix: String, jsons: [String]) {
        queues[pathSuffix, default: []].append(contentsOf: jsons.map { Data($0.utf8) })
    }

    /// All query items sent for the most recent request whose path ends in `suffix`.
    func queryItems(forPathSuffix suffix: String) -> [URLQueryItem]? {
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentQueryItems[index]
        }
        return nil
    }

    /// The HTTP method of the most recent request whose path ends in `suffix`.
    func method(forPathSuffix suffix: String) -> HTTPMethod? {
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentMethods[index]
        }
        return nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        sentPaths.append(endpoint.path)
        sentMethods.append(endpoint.method)
        sentQueryItems.append(endpoint.queryItems)
        if let error { throw error }

        func ok(_ data: Data, _ status: Int = 200) throws -> (Data, HTTPURLResponse) {
            switch status {
            case 200...299:
                return (data, HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case 401, 403: throw AppError.unauthorized
            case 404: throw AppError.notFound
            default: throw AppError.invalidResponse
            }
        }

        if let key = queues.keys.first(where: { endpoint.path.hasSuffix($0) }), var q = queues[key], !q.isEmpty {
            let next = q.removeFirst()
            queues[key] = q
            return try ok(next)
        }
        guard let match = responses.first(where: { endpoint.path.hasSuffix($0.suffix) })?.stub else {
            throw AppError.notFound
        }
        return try ok(match.body, match.status)
    }
}
