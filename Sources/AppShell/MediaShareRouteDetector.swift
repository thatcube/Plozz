#if canImport(SwiftUI)
import Foundation
import MediaTransportHTTP
#if canImport(Security)
import Security
#endif

/// Where a typed "Local media" address should be routed, after auto-detecting
/// the transport so the user never has to pick a protocol or type a scheme.
///
/// This is the *output vocabulary* the onboarding UI understands — one case per
/// transport that has its own onboarding flow. Adding a transport (NFS, FTP, …)
/// adds a case here plus a `TransportClaimant` (see below); the detector itself
/// stays generic and never needs editing.
enum MediaShareRoute: Equatable, Sendable {
    case smb(host: String, port: Int?)
    /// A fully-resolved WebDAV base URL (scheme already decided: https tried
    /// before http). `insecureHTTP` is true when it resolved to plain http.
    case webDAV(baseURL: URL, insecureHTTP: Bool)
    /// A fully-resolved FTP base URL (`ftp://` plaintext or `ftps://` implicit
    /// TLS). `insecure` is true for plaintext `ftp`.
    case ftp(baseURL: URL, insecure: Bool)
}

enum MediaShareRouteError: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable
}

/// A typed address parsed into its parts. `scheme` is nil when the user didn't
/// type one (the common, dead-simple case); `host` keeps IPv6 brackets; `path`
/// is "" or a leading-slash path.
struct ParsedShareAddress: Equatable, Sendable {
    /// The original trimmed string, preserved so an explicit-scheme claimant can
    /// honor exactly what the user typed (userinfo/query/etc.).
    var raw: String
    var scheme: String?   // lowercased, e.g. "smb", "http", "https"; nil if none
    var host: String      // may be an IPv6 literal in brackets, e.g. "[::1]"
    var port: Int?
    var path: String      // "" or "/..."
}

/// One transport's rules for claiming a typed address. The detector consults a
/// list of these and never hard-codes a specific transport, so adding a
/// transport = adding a claimant (no central edits). Detection runs in phases
/// across all claimants so intent is never lost:
///
///  1. **Decisive** (`decisiveRoute`) — a no-network claim from an explicit
///     scheme (`smb://`, `http(s)://`) or a well-known port (`445` → SMB). All
///     claimants get this phase before any probe, so a typed scheme is always
///     honored and never triggers another transport's network probe.
///  2. **Probe** (`probe`) — an active network check for an ambiguous address
///     (no owning scheme, no decisive port), in claimant priority order.
///
/// A terminal fallback (see `MediaShareRouteDetector`) handles the case where no
/// claimant probes positive.
protocol TransportClaimant: Sendable {
    /// Human-readable name, for diagnostics only.
    var transportName: String { get }
    /// Decisive, no-network claim from an explicit scheme or well-known port.
    /// Return a route only when this address is unambiguously ours; else nil.
    func decisiveRoute(for address: ParsedShareAddress) -> MediaShareRoute?
    /// Network probe for an ambiguous address. Return a route if this transport
    /// is present at the address, else nil. Only called when no scheme was typed.
    func probe(_ address: ParsedShareAddress) async -> MediaShareRoute?
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

/// Turns a raw typed address into a `MediaShareRoute` by consulting an ordered
/// list of `TransportClaimant`s. Deterministic and unit-testable (network
/// probes are injected via the claimants). The detector holds NO per-transport
/// knowledge beyond the fallback used when nothing claims the address.
struct MediaShareRouteDetector: Sendable {
    private let claimants: [any TransportClaimant]
    private let fallback: @Sendable (ParsedShareAddress) -> MediaShareRoute

    /// Full composition root — inject the claimant list (priority order) and the
    /// terminal fallback. This is the seam new transports plug into.
    init(
        claimants: [any TransportClaimant],
        fallback: @escaping @Sendable (ParsedShareAddress) -> MediaShareRoute
    ) {
        self.claimants = claimants
        self.fallback = fallback
    }

    /// Convenience for the shipping set (SMB + WebDAV), assuming SMB for a bare
    /// NAS host that answers no HTTP. `probe` is injectable for tests.
    /// The shipping detector's claimant set. `FTPClaimant` is active so a typed
    /// `ftp://`/`ftps://` address (or port 21) is detected; the resulting `.ftp`
    /// route is consumed by the unified add-share flow (Discovery-UX branch),
    /// which owns FTP credential entry + the plaintext-credential warning.
    init(probe: any WebDAVReachabilityProbing = WebDAVReachabilityProbe()) {
        self.init(
            claimants: [SMBClaimant(), WebDAVClaimant(probe: probe), FTPClaimant()],
            fallback: { .smb(host: $0.host, port: $0.port) }
        )
    }

    func detect(address rawAddress: String) async -> Result<MediaShareRoute, MediaShareRouteError> {
        let raw = rawAddress.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return .failure(.invalidAddress) }
        let parsed = Self.parse(raw)
        guard !parsed.host.isEmpty else { return .failure(.invalidAddress) }

        // 1. Explicit scheme: exactly one claimant owns it; an unknown scheme
        //    (e.g. a transport we don't support) is invalid rather than guessed.
        if parsed.scheme != nil {
            for claimant in claimants {
                if let route = claimant.decisiveRoute(for: parsed) { return .success(route) }
            }
            return .failure(.invalidAddress)
        }

        // 2. No scheme: a well-known port can still decide without a network hop.
        for claimant in claimants {
            if let route = claimant.decisiveRoute(for: parsed) { return .success(route) }
        }

        // 3. Actively probe, in claimant priority order.
        for claimant in claimants {
            if let route = await claimant.probe(parsed) { return .success(route) }
        }

        // 4. Terminal fallback (a bare NAS host that answers no probe is SMB).
        return .success(fallback(parsed))
    }

    // MARK: - Parsing

    /// Parses a raw address into scheme (if typed), host, optional port, path.
    /// IPv6 literals in brackets are preserved.
    static func parse(_ raw: String) -> ParsedShareAddress {
        var s = raw
        var scheme: String?
        if let range = s.range(of: "://") {
            scheme = String(s[..<range.lowerBound]).lowercased()
            s = String(s[range.upperBound...])
        }
        var authority = s
        var path = ""
        if let slash = s.firstIndex(of: "/") {
            authority = String(s[..<slash])
            path = String(s[slash...])
        }
        let (host, port) = splitAuthority(authority)
        return ParsedShareAddress(raw: raw, scheme: scheme, host: host, port: port, path: path)
    }

    /// Splits `host[:port]`, preserving an IPv6 literal's brackets.
    static func splitAuthority(_ authority: String) -> (host: String, port: Int?) {
        if authority.hasPrefix("[") {
            if let close = authority.firstIndex(of: "]") {
                let host = String(authority[...close])
                let rest = authority[authority.index(after: close)...]
                let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
                return (host, port)
            }
            return (authority, nil)
        }
        if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            return (String(authority[..<colon]), Int(authority[authority.index(after: colon)...]))
        }
        return (authority, nil)
    }
}

/// The `host[:port]` authority string used to build probe/base URLs.
private func authority(of address: ParsedShareAddress) -> String {
    address.port.map { "\(address.host):\($0)" } ?? address.host
}

// MARK: - Claimants

/// SMB claims `smb://` and port `445`. It has no network probe — it is the
/// assumed fallback for a bare NAS host, so its probe returns nil and the
/// detector's terminal fallback yields SMB.
struct SMBClaimant: TransportClaimant {
    var transportName: String { "SMB" }

    func decisiveRoute(for address: ParsedShareAddress) -> MediaShareRoute? {
        if address.scheme == "smb" {
            return .smb(host: address.host, port: address.port)
        }
        if address.scheme == nil, address.port == 445 {
            return .smb(host: address.host, port: address.port)
        }
        return nil
    }

    func probe(_ address: ParsedShareAddress) async -> MediaShareRoute? { nil }
}

/// WebDAV claims explicit `http(s)://`, and otherwise probes over HTTP (https
/// before http). It has NO decisive port: `80`/`443`/etc. are ambiguous (a NAS
/// web-admin page lives there too), so an un-schemed address is always probed.
struct WebDAVClaimant: TransportClaimant {
    let probe: any WebDAVReachabilityProbing

    var transportName: String { "WebDAV" }

    func decisiveRoute(for address: ParsedShareAddress) -> MediaShareRoute? {
        guard let scheme = address.scheme, scheme == "http" || scheme == "https" else {
            return nil
        }
        // Honor exactly what the user typed.
        guard let url = URL(string: address.raw), TransportOrigin(url: url) != nil else {
            return nil
        }
        return .webDAV(baseURL: url, insecureHTTP: scheme == "http")
    }

    func probe(_ address: ParsedShareAddress) async -> MediaShareRoute? {
        let hostPort = authority(of: address)
        if let httpsURL = URL(string: "https://\(hostPort)\(address.path)"),
           await probe.probe(url: httpsURL) == .httpServer {
            return .webDAV(baseURL: httpsURL, insecureHTTP: false)
        }
        if let httpURL = URL(string: "http://\(hostPort)\(address.path)"),
           await probe.probe(url: httpURL) == .httpServer {
            return .webDAV(baseURL: httpURL, insecureHTTP: true)
        }
        return nil
    }
}

/// FTP claims explicit `ftp://`/`ftps://`, and the well-known control port 21.
/// It has NO network probe — an un-schemed address without port 21 is left to
/// the other transports (WebDAV's HTTP probe / SMB's terminal fallback), so
/// adding FTP never changes how a bare NAS host is detected.
struct FTPClaimant: TransportClaimant {
    var transportName: String { "FTP" }

    func decisiveRoute(for address: ParsedShareAddress) -> MediaShareRoute? {
        if let scheme = address.scheme, scheme == "ftp" || scheme == "ftps" {
            // Honor exactly what the user typed.
            guard let url = URL(string: address.raw) else { return nil }
            return .ftp(baseURL: url, insecure: scheme == "ftp")
        }
        if address.scheme == nil, address.port == 21 {
            let hostPort = authority(of: address)
            guard let url = URL(string: "ftp://\(hostPort)\(address.path)") else { return nil }
            return .ftp(baseURL: url, insecure: true)
        }
        return nil
    }

    func probe(_ address: ParsedShareAddress) async -> MediaShareRoute? { nil }
}

// MARK: - Real HTTP probe

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
