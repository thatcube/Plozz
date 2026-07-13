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

/// Reachability result for one candidate WebDAV URL.
enum WebDAVReachability: Equatable, Sendable {
    case reachable      // an HTTP server answered (DAV header optional at this stage)
    case unreachable
}

/// Probes whether an HTTP(S) endpoint answers. For detection only — it accepts
/// any server certificate (a self-signed WebDAV server must still be
/// *detectable*; the real trust decision + pin approval happens later in the
/// WebDAV flow) and never sends credentials.
protocol WebDAVReachabilityProbing: Sendable {
    func reachability(of url: URL) async -> WebDAVReachability
}

/// Turns a raw typed address into a `MediaShareRoute`. Deterministic and
/// unit-testable (the network probe is injected).
///
/// Rules (no guessing games, and no unauthenticated DAV sniffing that real
/// servers don't reliably answer):
///  - explicit `smb://` → SMB; explicit `http(s)://` → WebDAV at that scheme.
///  - no scheme **with a path** (e.g. `nas.local/dav`) → WebDAV: probe https,
///    then http; whichever answers wins (so the user types neither scheme).
///  - no scheme, **bare host** (e.g. `192.168.2.1`) → SMB (the overwhelmingly
///    common bare-host LAN share; a WebDAV server virtually always lives under
///    a path, and the user can still type `http(s)://` to force WebDAV at root).
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
            guard let url = Self.webDAVURL(raw), TransportOrigin(url: url) != nil else {
                return .failure(.invalidAddress)
            }
            return .success(.webDAV(baseURL: url, insecureHTTP: url.scheme?.lowercased() == "http"))
        }

        // No scheme: split host/port/path.
        let (host, port, path) = Self.split(raw, droppingScheme: nil)
        guard !host.isEmpty else { return .failure(.invalidAddress) }

        let hasPath = !path.isEmpty && path != "/"
        guard hasPath else {
            // Bare host → SMB.
            return .success(.smb(host: host, port: port))
        }

        // Host + path → WebDAV. Probe https first, then http.
        let hostPort = port.map { "\(host):\($0)" } ?? host
        if let httpsURL = URL(string: "https://\(hostPort)\(path)"),
           await probe.reachability(of: httpsURL) == .reachable {
            return .success(.webDAV(baseURL: httpsURL, insecureHTTP: false))
        }
        if let httpURL = URL(string: "http://\(hostPort)\(path)"),
           await probe.reachability(of: httpURL) == .reachable {
            return .success(.webDAV(baseURL: httpURL, insecureHTTP: true))
        }
        return .failure(.unreachable)
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

    private static func webDAVURL(_ raw: String) -> URL? {
        URL(string: raw)
    }
}

/// Real reachability probe: a short-timeout `OPTIONS` that accepts any server
/// trust and reports whether an HTTP response came back. Credential-free.
struct WebDAVReachabilityProbe: WebDAVReachabilityProbing {
    func reachability(of url: URL) async -> WebDAVReachability {
        await withCheckedContinuation { continuation in
            let delegate = AnyTrustProbeDelegate()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.httpMethod = "OPTIONS"
            let box = ContinuationBox(continuation)
            let task = session.dataTask(with: request) { _, response, _ in
                let reachable = response is HTTPURLResponse
                box.resume(reachable ? .reachable : .unreachable)
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebDAVReachability, Never>?
    init(_ continuation: CheckedContinuation<WebDAVReachability, Never>) {
        self.continuation = continuation
    }
    func resume(_ value: WebDAVReachability) {
        let cont = lock.withLock { () -> CheckedContinuation<WebDAVReachability, Never>? in
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
