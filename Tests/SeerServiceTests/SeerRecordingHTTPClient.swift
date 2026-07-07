import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Recording `HTTPClient` test double for Seerr. Matches stubbed responses by
/// path suffix and captures sent requests (path, headers, body) so tests can
/// assert on request payloads (e.g. the POST /request body).
final class SeerRecordingHTTPClient: HTTPClient, @unchecked Sendable {
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

    private var responses: [String: Stub] = [:]
    var error: AppError?
    private(set) var sent: [Sent] = []
    private let lock = NSLock()

    func stub(pathSuffix: String, json: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        responses[pathSuffix] = Stub(status: status, body: Data(json.utf8))
    }

    var sentPaths: [String] { lock.lock(); defer { lock.unlock() }; return sent.map(\.path) }

    func lastSent(pathSuffix: String) -> Sent? {
        lock.lock(); defer { lock.unlock() }
        return sent.last { $0.path.hasSuffix(pathSuffix) }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await sendRaw(endpoint, baseURL: baseURL)
        switch response.statusCode {
        case 200...299: return (data, response)
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        case 409: throw AppError.conflict
        default: throw AppError.invalidResponse
        }
    }

    /// Records the request, then returns the stubbed `(data, response)` for **any**
    /// status (only an injected transport `error` or a missing stub throws) — so
    /// createRequest can inspect the status code + error body.
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sent.append(Sent(path: endpoint.path, headers: endpoint.headers, body: endpoint.body))
        if let error { lock.unlock(); throw error }
        let match = responses.first { endpoint.path.hasSuffix($0.key) }?.value
        lock.unlock()
        guard let stub = match else { throw AppError.notFound }
        let response = HTTPURLResponse(url: baseURL, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        return (stub.body, response)
    }
}
