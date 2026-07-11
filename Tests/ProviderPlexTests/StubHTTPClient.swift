import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configurable `HTTPClient` test double matching by path suffix, mirroring the
/// ProviderJellyfin test stub.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    var responses: [(suffix: String, stub: Stub)] = []
    private var queues: [String: [Data]] = [:]
    var error: AppError?
    private(set) var sentPaths: [String] = []
    private(set) var sentMethods: [HTTPMethod] = []
    private(set) var sentQueryItems: [[URLQueryItem]] = []
    private(set) var sentBaseURLs: [URL] = []

    func stub(
        pathSuffix: String,
        json: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) {
        responses.append((
            pathSuffix,
            Stub(status: status, body: Data(json.utf8), headers: headers)
        ))
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

    /// The method of the most recent request whose path ends in `suffix`.
    func method(forPathSuffix suffix: String) -> HTTPMethod? {
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentMethods[index]
        }
        return nil
    }

    /// The base URL (host) of the most recent request whose path ends in `suffix`.
    func baseURL(forPathSuffix suffix: String) -> URL? {
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentBaseURLs[index]
        }
        return nil
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
        sentPaths.append(endpoint.path)
        sentMethods.append(endpoint.method)
        sentQueryItems.append(endpoint.queryItems)
        sentBaseURLs.append(baseURL)
        if let error { throw error }

        func response(
            _ data: Data,
            _ status: Int = 200,
            headers: [String: String] = [:]
        ) -> (Data, HTTPURLResponse) {
            (
                data,
                HTTPURLResponse(
                    url: baseURL,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        }

        if let key = queues.keys.first(where: { endpoint.path.hasSuffix($0) }), var q = queues[key], !q.isEmpty {
            let next = q.removeFirst()
            queues[key] = q
            return response(next)
        }
        guard let match = responses.first(where: { endpoint.path.hasSuffix($0.suffix) })?.stub else {
            throw AppError.notFound
        }
        return response(match.body, match.status, headers: match.headers)
    }
}
