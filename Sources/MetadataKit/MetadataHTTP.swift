import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tiny best-effort JSON transport shared by the keyless metadata providers.
///
/// Deliberately separate from `CoreNetworking.HTTPClient` (whose error mapping and
/// auth model target the user's own server): these calls hit public third-party
/// APIs, must never throw into the UI, and just want "decode this or give me nil".
enum MetadataHTTP {
    /// A polite, identifying User-Agent. MusicBrainz *requires* one; the rest
    /// simply behave better when traffic is attributable.
    static let userAgent = "Plozz/1.0 (+https://github.com/thatcube/Plozz)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        // Let URLCache hold the JSON responses so repeat lookups within a run are
        // cheap even before the persistent MetadataDiskCache is consulted.
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// GET `url` and decode `T`, returning `nil` on any failure (network, non-2xx,
    /// decode). `accept` defaults to JSON.
    static func get<T: Decodable>(
        _ type: T.Type,
        url: URL,
        accept: String = "application/json",
        headers: [String: String] = [:],
        decoder: JSONDecoder = JSONDecoder()
    ) async -> T? {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return await perform(type, request: request, decoder: decoder)
    }

    /// POST a JSON `body` to `url` (used for AniList's GraphQL endpoint) and decode
    /// `T`, returning `nil` on any failure.
    static func postJSON<T: Decodable>(
        _ type: T.Type,
        url: URL,
        body: [String: Any],
        decoder: JSONDecoder = JSONDecoder()
    ) async -> T? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard request.httpBody != nil else { return nil }
        return await perform(type, request: request, decoder: decoder)
    }

    /// Like `get`, but also reports whether the server actually answered. The
    /// `reachable` flag is `true` when we got *any* HTTP response back (even a
    /// 404), and `false` only when the transport itself failed (offline, DNS,
    /// TLS, timeout). Used by the lyrics layer to avoid caching a negative
    /// result when the user is simply disconnected.
    static func getWithStatus<T: Decodable>(
        _ type: T.Type,
        url: URL,
        accept: String = "application/json",
        headers: [String: String] = [:],
        decoder: JSONDecoder = JSONDecoder()
    ) async -> (value: T?, reachable: Bool) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return await performWithStatus(type, request: request, decoder: decoder)
    }

    private static func perform<T: Decodable>(
        _ type: T.Type,
        request: URLRequest,
        decoder: JSONDecoder
    ) async -> T? {
        await performWithStatus(type, request: request, decoder: decoder).value
    }

    private static func performWithStatus<T: Decodable>(
        _ type: T.Type,
        request: URLRequest,
        decoder: JSONDecoder
    ) async -> (value: T?, reachable: Bool) {
        guard let (data, response) = try? await session.data(for: request) else {
            return (nil, false)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return (nil, true)
        }
        return (try? decoder.decode(T.self, from: data), true)
    }
}

/// URL-encodes `value` for a query item, returning `nil` when empty.
func metadataEscaped(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
}
