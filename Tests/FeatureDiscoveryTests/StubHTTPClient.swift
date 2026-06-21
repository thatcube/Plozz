import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configurable `HTTPClient` test double that matches requests by path suffix.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data
    }

    /// path-suffix → stub
    var responses: [String: Stub] = [:]
    var error: AppError?
    private(set) var sentPaths: [String] = []

    init() {}

    func stub(path: String, json: String, status: Int = 200) {
        responses[path] = Stub(status: status, body: Data(json.utf8))
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        sentPaths.append(endpoint.path)
        if let error { throw error }
        guard let match = responses.first(where: { endpoint.path.hasSuffix($0.key) })?.value else {
            throw AppError.notFound
        }
        switch match.status {
        case 200...299:
            let response = HTTPURLResponse(url: baseURL, statusCode: match.status, httpVersion: nil, headerFields: nil)!
            return (match.body, response)
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        default: throw AppError.invalidResponse
        }
    }
}
