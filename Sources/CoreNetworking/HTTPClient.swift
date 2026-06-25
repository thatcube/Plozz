import Foundation
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        decoder: JSONDecoder = .plozz
    ) async throws -> T {
        let (data, _) = try await send(endpoint, baseURL: baseURL)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            PlozzLog.networking.error("Decoding \(String(describing: T.self)) failed")
            throw AppError.decoding
        }
    }
}

/// `URLSession`-backed `HTTPClient`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .plozzDefault) {
        self.session = session
    }

    public func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let request = try Self.makeRequest(endpoint, baseURL: baseURL)

        PlozzLog.networking.debug(
            "→ \(endpoint.method.rawValue) \(PlozzLog.redact(url: request.url ?? baseURL))"
        )

        let data: Data
        let response: URLResponse
        let _dlogStart = Date()
        let _dlogURL = request.url?.absoluteString ?? baseURL.absoluteString
        DLog.mark("HTTP → \(endpoint.method.rawValue) \(_dlogURL)")
        do {
            (data, response) = try await session.data(for: request)
            DLog.mark(String(format: "HTTP ✓ %.0fms %@", Date().timeIntervalSince(_dlogStart) * 1000, _dlogURL))
        } catch let urlError as URLError {
            DLog.mark(String(format: "HTTP ✗ %.0fms %@ err=%@", Date().timeIntervalSince(_dlogStart) * 1000, _dlogURL, "\(urlError.code.rawValue)"))
            throw Self.map(urlError)
        } catch is CancellationError {
            DLog.mark(String(format: "HTTP ⊘cancel %.0fms %@", Date().timeIntervalSince(_dlogStart) * 1000, _dlogURL))
            throw AppError.cancelled
        } catch {
            DLog.mark(String(format: "HTTP ✗ %.0fms %@ err=%@", Date().timeIntervalSince(_dlogStart) * 1000, _dlogURL, "\(error)"))
            throw AppError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        PlozzLog.networking.debug("← \(http.statusCode)")

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
    static var plozzDefault: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        // A detail open fans out a burst of enrichment requests (season prewarm,
        // trailers, ratings, cross-server discovery) to the SAME server host. With
        // the system default per-host cap (~6) those background requests can occupy
        // every socket and starve the next page's foreground fetch. A higher cap
        // keeps the pool from becoming the bottleneck on a fast LAN.
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Dedicated lane for FOREGROUND, user-blocking fetches — specifically opening
    /// a detail page (`item`/`metadata`). It has its OWN connection pool, so a
    /// critical-path fetch can NEVER be starved waiting for a free socket behind
    /// the background enrichment storm running on ``plozzDefault`` (season prewarm,
    /// trailers, ratings, cross-server discovery). `timeoutIntervalForRequest`
    /// does not count time spent queued for a connection, so a shared pool let a
    /// foreground fetch sit ~18s behind background work before `timeoutInterval-
    /// ForResource` (30s) would even fire — this isolated pool removes that queue
    /// entirely. Short timeouts so a genuinely slow server fails fast into a
    /// graceful error instead of a long blank hang.
    static var plozzInteractive: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Session for probing discovery candidates: very short timeouts so we can
    /// race several candidate URLs per server and fail fast on the wrong ones
    /// without stalling the scan. Does not wait for connectivity.
    static var plozzDiscovery: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }
}

public extension JSONDecoder {
    /// Decoder configured for Jellyfin's PascalCase JSON.
    static var plozz: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
