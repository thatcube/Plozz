#if canImport(SwiftUI)
import Foundation
import MediaTransportHTTP
#if canImport(Security)
import Security
#endif

/// Where a typed "Local media" address should be routed, after auto-detecting
/// the transport so the user never has to pick SMB vs WebDAV or type a scheme.
enum MediaShareRoute: Equatable, Sendable {
    case smb(host: String, port: Int?)
    /// A fully-resolved WebDAV base URL (scheme already decided: https tried
    /// before http). `insecureHTTP` is true when it resolved to plain http.
    case webDAV(baseURL: URL, insecureHTTP: Bool)
}

enum MediaShareRouteError: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable
}

/// Result of probing one candidate URL over HTTP.
///
/// We deliberately do NOT require a `DAV` header here: the common case is an
/// auth-gated WebDAV server (e.g. Apache `mod_dav` behind Basic auth) that
/// answers an unauthenticated `OPTIONS` with `401` and *no* `DAV` header,
/// because the auth check runs before mod_dav adds the header. Since SMB never
/// speaks HTTP, *any* HTTP response rules SMB out for that host:port — so we
/// route it to the WebDAV flow, which then confirms `DAV` *with* credentials
/// and errors clearly if it turns out not to be WebDAV.
enum WebDAVProbeResult: Equatable, Sendable {
    case httpServer   // an HTTP server answered (any status, incl. 401 auth)
    case unreachable  // nothing HTTP answered (refused / timeout / non-HTTP)
}

/// Probes whether an HTTP(S) server answers at an endpoint. For detection only —
/// it accepts any server certificate (a self-signed WebDAV server must still be
/// *detectable*; the real trust decision + pin approval happens later in the
/// WebDAV flow) and never sends credentials.
protocol WebDAVReachabilityProbing: Sendable {
    func probe(url: URL) async -> WebDAVProbeResult
}

/// Turns a raw typed address into a `MediaShareRoute`. Deterministic and
/// unit-testable (the network probe is injected).
///
/// No path heuristics and no "which port means what" guessing — it **probes**:
///  - explicit `smb://` → SMB; explicit `http(s)://` → WebDAV at that scheme
///    (the user stated intent; the WebDAV flow's own `OPTIONS`+`DAV` check
///    confirms it and errors clearly if it isn't WebDAV).
///  - port `445` → SMB (that's SMB's port, unambiguous).
///  - otherwise → probe the address over HTTP (`OPTIONS`), trying https then
///    http; if an HTTP server answers (even a `401` auth challenge, which is how
///    an auth-gated WebDAV server responds), route WebDAV at that scheme; if
///    nothing HTTP answers, fall back to SMB. So `192.168.68.71:8384` (a WebDAV
///    server on a non-standard port, no path, behind Basic auth) is correctly
///    detected, and a host with only SMB (no HTTP at all) falls back to SMB.
struct MediaShareRouteDetector: Sendable {
    private let probe: any WebDAVReachabilityProbing

    init(probe: any WebDAVReachabilityProbing = WebDAVReachabilityProbe()) {
        self.probe = probe
    }

    func detect(address rawAddress: String) async -> Result<MediaShareRoute, MediaShareRouteError> {
        let raw = rawAddress.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return .failure(.invalidAddress) }
        let lower = raw.lowercased()

        // Explicit scheme is always honored.
        if lower.hasPrefix("smb://") {
            let (host, port, _) = Self.split(raw, droppingScheme: "smb://")
            guard !host.isEmpty else { return .failure(.invalidAddress) }
            return .success(.smb(host: host, port: port))
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: raw), TransportOrigin(url: url) != nil else {
                return .failure(.invalidAddress)
            }
            return .success(.webDAV(baseURL: url, insecureHTTP: url.scheme?.lowercased() == "http"))
        }

        // No scheme: split host/port/path.
        let (host, port, path) = Self.split(raw, droppingScheme: nil)
        guard !host.isEmpty else { return .failure(.invalidAddress) }

        // Port 445 is unambiguously SMB.
        if port == 445 {
            return .success(.smb(host: host, port: port))
        }

        // Probe over HTTP (https first, then http) on the given port/path. An
        // HTTP server answering — even a 401 auth challenge — means it isn't
        // SMB, so route to WebDAV (which confirms DAV with credentials next).
        let hostPort = port.map { "\(host):\($0)" } ?? host
        if let httpsURL = URL(string: "https://\(hostPort)\(path)"),
           await probe.probe(url: httpsURL) == .httpServer {
            return .success(.webDAV(baseURL: httpsURL, insecureHTTP: false))
        }
        if let httpURL = URL(string: "http://\(hostPort)\(path)"),
           await probe.probe(url: httpURL) == .httpServer {
            return .success(.webDAV(baseURL: httpURL, insecureHTTP: true))
        }

        // No HTTP server answered → treat as SMB (its own flow validates/errors).
        return .success(.smb(host: host, port: port))
    }

    // MARK: - Parsing helpers

    /// Splits a raw address into (host, port, path). Tolerates an optional
    /// scheme prefix (stripped by the caller via `droppingScheme`), an inline
    /// `:port`, and a `/path`. IPv6 literals in brackets are preserved.
    static func split(_ raw: String, droppingScheme scheme: String?) -> (host: String, port: Int?, path: String) {
        var s = raw
        if let scheme, s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        } else if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        // Split off the path at the first slash.
        var authority = s
        var path = ""
        if let slash = s.firstIndex(of: "/") {
            authority = String(s[..<slash])
            path = String(s[slash...])
        }
        // IPv6 literal: [::1]:port
        if authority.hasPrefix("[") {
            if let close = authority.firstIndex(of: "]") {
                let host = String(authority[...close])
                let rest = authority[authority.index(after: close)...]
                let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
                return (host, port, path)
            }
            return (authority, nil, path)
        }
        // host[:port]
        if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            let host = String(authority[..<colon])
            let port = Int(authority[authority.index(after: colon)...])
            return (host, port, path)
        }
        return (authority, nil, path)
    }
}

/// Real HTTP probe: a short-timeout `OPTIONS` that accepts any server trust and
/// reports whether an HTTP server answered at all (any status). Credential-free.
struct WebDAVReachabilityProbe: WebDAVReachabilityProbing {
    func probe(url: URL) async -> WebDAVProbeResult {
        await withCheckedContinuation { continuation in
            let delegate = AnyTrustProbeDelegate()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.httpMethod = "OPTIONS"
            let box = ContinuationBox(continuation)
            let task = session.dataTask(with: request) { _, response, _ in
                box.resume(response is HTTPURLResponse ? .httpServer : .unreachable)
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebDAVProbeResult, Never>?
    init(_ continuation: CheckedContinuation<WebDAVProbeResult, Never>) {
        self.continuation = continuation
    }
    func resume(_ value: WebDAVProbeResult) {
        let cont = lock.withLock { () -> CheckedContinuation<WebDAVProbeResult, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(returning: value)
    }
}

#if canImport(Security)
/// Accepts any server certificate — used ONLY for credential-free detection
/// reachability, so a self-signed WebDAV server is still *findable*. The real
/// trust evaluation + leaf-pin approval happens afterward in the WebDAV flow.
private final class AnyTrustProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#else
private final class AnyTrustProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {}
#endif
#endif
