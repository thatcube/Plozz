import Foundation
import CoreModels

/// Abstraction over the transport so providers can be unit-tested with a stub.
public protocol HTTPClient: Sendable {
    /// Sends `endpoint` against `baseURL`, returning raw data + response.
    /// Throws `AppError` for transport/status failures (non-2xx → mapped).
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPClient {
    /// Sends and decodes a JSON `Decodable`, mapping failures to `AppError`.
    func decode<T: Decodable>(
        _ type: T.Type,
        from endpoint: Endpoint,
        baseURL: URL,
        decoder: JSONDecoder = .plizz
    ) async throws -> T {
        let (data, _) = try await send(endpoint, baseURL: baseURL)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            PlizzLog.networking.error("Decoding \(String(describing: T.self)) failed")
            throw AppError.decoding
        }
    }
}

/// `URLSession`-backed `HTTPClient`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .plizzDefault) {
        self.session = session
    }

    public func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let request = try Self.makeRequest(endpoint, baseURL: baseURL)

        PlizzLog.networking.debug(
            "→ \(endpoint.method.rawValue, privacy: .public) \(PlizzLog.redact(url: request.url ?? baseURL), privacy: .public)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw Self.map(urlError)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        PlizzLog.networking.debug("← \(http.statusCode, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401, 403:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.invalidResponse
        }
    }

    static func makeRequest(_ endpoint: Endpoint, baseURL: URL) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        // Append the endpoint path to any base path the server is hosted under.
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + endpoint.path
        if !endpoint.queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + endpoint.queryItems
        }
        guard let url = components.url else { throw AppError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func map(_ error: URLError) -> AppError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .timedOut, .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed:
            return .serverUnreachable
        default:
            return .serverUnreachable
        }
    }
}

public extension URLSession {
    /// Session tuned for tvOS: short-ish timeouts so the UI can fail fast and
    /// show a graceful "server unreachable" state instead of hanging.
    static var plizzDefault: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}

public extension JSONDecoder {
    /// Decoder configured for Jellyfin's PascalCase JSON.
    static var plizz: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
