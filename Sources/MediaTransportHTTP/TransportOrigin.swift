import Foundation

/// An exact HTTP(S) origin: scheme + host + port, with the default port made
/// explicit so two URLs that mean the same origin always compare equal
/// (`https://h/a` and `https://h:443/a`), and two that don't (different
/// scheme, host, or port) never do.
///
/// This is the unit every redirect/auth-forwarding/session-key decision in
/// this module is keyed on. Deliberately narrower than `URL` equality (which
/// cares about path/query) and than "same host" (which ignores scheme/port
/// and would let an HTTPS session get redirected onto plain HTTP silently).
public struct TransportOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    /// Fails for anything that isn't a well-formed `http`/`https` URL with a
    /// host. Scheme and host are lower-cased so comparisons are
    /// case-insensitive per RFC 3986 §3.1/§3.2.2.
    public init?(url: URL) {
        guard url.user == nil, url.password == nil else {
            return nil
        }
        guard let rawScheme = url.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https" else {
            return nil
        }
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return nil
        }
        let effectivePort = url.port ?? TransportOrigin.defaultPort(forScheme: rawScheme)
        guard (1...65_535).contains(effectivePort) else {
            return nil
        }
        self.scheme = rawScheme
        self.host = rawHost
        self.port = effectivePort
    }

    init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard scheme == "http" || scheme == "https",
              !host.isEmpty,
              (1...65_535).contains(port) else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public var isSecure: Bool { scheme == "https" }

    /// Human-readable form for diagnostics/error messages. Contains no path,
    /// query, or userinfo, so it is always safe to log.
    public var displayString: String {
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(displayedHost):\(port)"
    }

    func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        if port != TransportOrigin.defaultPort(forScheme: scheme) {
            components.port = port
        }
        components.path = path
        return components.url
    }

    static func defaultPort(forScheme scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}

/// Strips userinfo (`user:password@`) and query string from a URL before it
/// is used in a log line or error message. Belt-and-suspenders: this module
/// never *puts* credentials in a URL, but a server-supplied redirect target
/// or a caller-supplied malformed input could still carry one, and no
/// diagnostic string anywhere in this module may echo it back.
public func redactedURLDescription(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return "<invalid-url>"
    }
    components.user = nil
    components.password = nil
    components.queryItems = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "\(components.scheme ?? "?")://\(components.host ?? "?")"
}

/// Decision produced by evaluating a redirect against the same-origin policy.
public enum RedirectDecision: Equatable, Sendable {
    /// Proceed with `request` (already sanitized: `Authorization` retained
    /// only because the target is same-origin).
    case follow(URLRequest)
    /// Refuse the redirect; the task should fail with the wrapped error.
    case reject(TransportError)
}

/// Same-origin-only HTTP redirect policy.
///
/// Rules (all mandatory, none configurable — a WebDAV/HTTP transport that
/// silently followed a cross-origin or downgrading redirect while carrying
/// auth would leak credentials to an attacker-controlled or plaintext
/// endpoint):
///  - the redirect target must resolve to the **exact same** `TransportOrigin`
///    as the original request (scheme + host + port);
///  - an HTTPS → HTTP redirect is always rejected, even to the same host;
///  - a cross-host or cross-port redirect is always rejected;
///  - only when the origin is unchanged is `Authorization` (and any other
///    header) retained on the follow-up request — this module never forwards
///    auth to a different origin.
public enum RedirectPolicy {
    /// Pure function: given the request that was redirected and the
    /// `Location` the server wants to send us to, decide whether to follow.
    /// No I/O — trivially unit-testable without a network stack.
    public static func evaluate(
        original request: URLRequest,
        newRequest: URLRequest
    ) -> RedirectDecision {
        guard let requestURL = request.url, let originOrigin = TransportOrigin(url: requestURL) else {
            return .reject(.invalidOrigin(reason: "original request has no valid URL"))
        }
        guard let newURL = newRequest.url, let newOrigin = TransportOrigin(url: newURL) else {
            return .reject(.invalidOrigin(reason: "redirect target has no valid URL"))
        }

        guard newOrigin == originOrigin else {
            if originOrigin.isSecure && !newOrigin.isSecure {
                return .reject(
                    .insecureRedirectDowngradeRejected(
                        from: originOrigin.displayString,
                        to: newOrigin.displayString
                    )
                )
            }
            return .reject(
                .crossOriginRedirectRejected(
                    from: originOrigin.displayString,
                    to: newOrigin.displayString
                )
            )
        }

        // Same-origin: safe to retain Authorization (and everything else)
        // from the original request onto the redirected one. `URLSession`
        // does not reliably guarantee this itself across platforms, so we
        // make it explicit rather than relying on default redirect behavior.
        var sanitized = newRequest
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            sanitized.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return .follow(sanitized)
    }
}
