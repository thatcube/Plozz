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

    /// Like `get`, but also reports whether the answer is *authoritative* enough
    /// to trust as a real negative. The `reachable` flag is `true` for a decoded
    /// 2xx response **or** a definitive `404 Not Found`, and `false` when the
    /// transport itself failed (offline, DNS, TLS, timeout) **or** the server
    /// returned a transient/ambiguous error (429 rate-limit, any 5xx, 408/425,
    /// or a 4xx like 400). The lyrics layer uses this to avoid burning a
    /// permanent "no lyrics" into its cache when the device is disconnected or
    /// LRCLIB merely throttled/hiccuped under the prefetch fan-out — see
    /// `nonSuccessIsAuthoritative`.
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

    /// The classified outcome of a metadata HTTP call, so a provider can report
    /// ``ProviderHealth`` to its circuit breaker instead of collapsing every failure
    /// into `nil`.
    enum Outcome<T: Sendable>: Sendable {
        case success(T)
        /// Decoded but empty, or a definitive 404 — an authoritative negative.
        case empty
        /// 401 / 403.
        case unauthorized
        /// 429, with the server's `Retry-After` in seconds when present.
        case rateLimited(retryAfter: TimeInterval?)
        /// Offline / DNS / TLS / timeout / 5xx / other non-authoritative failure.
        case transient
    }

    /// Like ``get(_:url:accept:headers:decoder:)`` but classifies the transport
    /// result so callers can drive a circuit breaker.
    static func getOutcome<T: Decodable>(
        _ type: T.Type,
        url: URL,
        accept: String = "application/json",
        headers: [String: String] = [:],
        decoder: JSONDecoder = JSONDecoder()
    ) async -> Outcome<T> {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await session.data(for: request) else {
            return .transient
        }
        if let http = response as? HTTPURLResponse {
            let code = http.statusCode
            switch code {
            case 200...299:
                if let value = try? decoder.decode(T.self, from: data) { return .success(value) }
                return .empty
            case 404:
                return .empty
            case 401, 403:
                return .unauthorized
            case 429:
                return .rateLimited(retryAfter: retryAfterSeconds(http))
            default:
                return .transient
            }
        }
        if let value = try? decoder.decode(T.self, from: data) { return .success(value) }
        return .transient
    }

    /// Parses a `Retry-After` header (delta-seconds; an HTTP-date is treated as an
    /// unknown delay so the breaker uses its fallback cooldown).
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = (response.value(forHTTPHeaderField: "Retry-After"))?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        return nil
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
            return (nil, nonSuccessIsAuthoritative(http.statusCode))
        }
        return (try? decoder.decode(T.self, from: data), true)
    }

    /// Whether a non-2xx HTTP status is an *authoritative* answer the lyrics
    /// layer may trust as a real negative (→ `reachable: true`), versus a
    /// transient or ambiguous failure that must never be cached as "no lyrics"
    /// (→ `reachable: false`).
    ///
    /// Only a definitive `404 Not Found` qualifies as authoritative: it means the
    /// record genuinely isn't there. Everything else — `429` (rate-limited, which
    /// the app's own prefetch fan-out provokes), any `5xx` (LRCLIB / Cloudflare
    /// 500/502/503/520/522…), `408`/`425` (timeouts), and other `4xx` such as a
    /// `400` from a malformed query (e.g. a track longer than LRCLIB's 3600s
    /// `/get` cap) — is transient or a non-verdict, so the resolver re-tries on a
    /// later play instead of poisoning the cache with a permanent miss.
    static func nonSuccessIsAuthoritative(_ statusCode: Int) -> Bool {
        statusCode == 404
    }
}

/// URL-encodes `value` for a query item, returning `nil` when empty.
func metadataEscaped(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
}
