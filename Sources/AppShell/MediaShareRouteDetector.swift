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

/// Result of probing one candidate URL for WebDAV.
enum WebDAVProbeResult: Equatable, Sendable {
    case webDAV       // an HTTP server answered AND advertised the DAV header
    case notWebDAV    // an HTTP server answered but is not WebDAV
    case unreachable  // nothing answered (or TLS failed)
}

/// Probes whether an HTTP(S) endpoint is a WebDAV server. For detection only —
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
///  - otherwise → probe the address for WebDAV (`OPTIONS` → `DAV` header),
///    trying https then http; if a WebDAV server answers, route WebDAV at that
///    scheme; if not, fall back to SMB. So `192.168.68.71:8384` (a WebDAV
///    server on a non-standard port, no path) is correctly detected, and a bare
///    NAS with only a web admin page is not mistaken for WebDAV.
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

        // Probe for a WebDAV server (https first, then http) on the given
        // port/path, matching a real DAV response — not a path or port guess.
        let hostPort = port.map { "\(host):\($0)" } ?? host
        if let httpsURL = URL(string: "https://\(hostPort)\(path)"),
           await probe.probe(url: httpsURL) == .webDAV {
            return .success(.webDAV(baseURL: httpsURL, insecureHTTP: false))
        }
        if let httpURL = URL(string: "http://\(hostPort)\(path)"),
           await probe.probe(url: httpURL) == .webDAV {
            return .success(.webDAV(baseURL: httpURL, insecureHTTP: true))
        }

        // Not a WebDAV server → treat as SMB (its own flow validates/erros).
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

/// Real WebDAV probe: a short-timeout `OPTIONS` that accepts any server trust
/// and reports whether the response advertised the `DAV` compliance header
/// (RFC 4918 §10.1). Credential-free.
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
                let result: WebDAVProbeResult
                if let http = response as? HTTPURLResponse {
                    let headers = HTTPHeaderUtilities.normalizedHeaders(from: http.allHeaderFields)
                    result = headers["dav"] != nil ? .webDAV : .notWebDAV
                } else {
                    result = .unreachable
                }
                box.resume(result)
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
