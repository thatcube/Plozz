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
    private(set) var sentPaths: [String] = []
    private(set) var sentQueryItems: [[URLQueryItem]] = []

    func stub(pathSuffix: String, json: String, status: Int = 200) {
        responses.append((pathSuffix, Stub(status: status, body: Data(json.utf8))))
    }

    /// All query items sent for the most recent request whose path ends in `suffix`.
    func queryItems(forPathSuffix suffix: String) -> [URLQueryItem]? {
        for (index, path) in sentPaths.enumerated().reversed() where path.hasSuffix(suffix) {
            return sentQueryItems[index]
        }
        return nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        sentPaths.append(endpoint.path)
        sentQueryItems.append(endpoint.queryItems)
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
