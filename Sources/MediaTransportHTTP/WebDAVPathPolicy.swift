import Foundation

/// The configured WebDAV root a browse session is scoped to: an origin plus
/// a normalized base path. Every href returned by a `PROPFIND` is resolved
/// and validated against this root before it's trusted.
public struct WebDAVRoot: Sendable, Equatable {
    public let origin: TransportOrigin
    /// Normalized, percent-decoded path. Always begins with `/`. Trailing
    /// slash is preserved when present (root itself is a collection).
    public let path: String

    public init?(origin: TransportOrigin, rawPath: String) {
        guard let normalized = WebDAVPathPolicy.normalizedPath(rawPath) else { return nil }
        self.origin = origin
        self.path = normalized
    }

    init(origin: TransportOrigin, normalizedPath: String) {
        self.origin = origin
        self.path = normalizedPath
    }
}

/// Path/origin containment policy for resolving `PROPFIND` hrefs.
///
/// A malicious or misconfigured server could return an href that points
/// outside the folder the user configured (`../../etc/passwd`-style
/// traversal, an absolute href on a *different* origin, or a root-relative
/// href above the configured root). None of that may ever be silently
/// accepted — every href is normalized and must resolve to a path at or
/// under the configured root, on the configured origin, or it's rejected.
public enum WebDAVPathPolicy {
    /// Percent-decodes and normalizes a raw path string into a form safe to
    /// prefix-compare: splits on `/`, decodes each segment, drops empty
    /// segments (collapsing `//`) and `.` segments, and — critically —
    /// **rejects** (`nil`) if any segment decodes to `..`. Traversal
    /// segments are never silently resolved/popped; their mere presence
    /// after decoding is treated as hostile input.
    ///
    /// Preserves a trailing slash (collection marker) when the input path
    /// ends with `/` and isn't empty.
    public static func normalizedPath(_ rawPath: String) -> String? {
        // Query/fragment carry no meaning for WebDAV resource identity and
        // are a common smuggling vector; ignore anything after them.
        let withoutQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let withoutFragment = withoutQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let raw = String(withoutFragment)

        let hadTrailingSlash = raw.count > 1 && raw.hasSuffix("/")
        let rawSegments = raw.split(separator: "/", omittingEmptySubsequences: true)

        var decodedSegments: [String] = []
        decodedSegments.reserveCapacity(rawSegments.count)
        for segment in rawSegments {
            guard let decoded = segment.removingPercentEncoding else { return nil }
            if decoded == "." { continue }
            if decoded == ".." { return nil } // traversal — reject, never resolve away.
            guard !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return nil
            }
            decodedSegments.append(decoded)
        }

        let joined = "/" + decodedSegments.joined(separator: "/")
        if decodedSegments.isEmpty { return "/" }
        return hadTrailingSlash ? joined + "/" : joined
    }

    static func isNormalizedDecodedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let hadTrailingSlash = path.count > 1 && path.hasSuffix("/")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        for segment in segments {
            let value = String(segment)
            guard value != ".",
                  value != "..",
                  !value.contains("\\"),
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return false
            }
        }
        let rebuilt = "/" + segments.joined(separator: "/") + (hadTrailingSlash ? "/" : "")
        return rebuilt == path
    }

    /// Resolves one `PROPFIND` href against `root` and the path that was
    /// queried (`requestPath`, already normalized, used as the relative
    /// base per RFC 3986). Returns the normalized, root-relative path on
    /// success and throws if the href is cross-origin, malformed, or escapes
    /// the configured root.
    public static func resolve(href rawHref: String, root: WebDAVRoot, requestPath: String) throws -> String {
        guard !rawHref.isEmpty else {
            throw TransportError.malformedMultistatus(reason: "response href is empty")
        }

        guard let base = root.origin.url(path: requestPath),
              let resolved = URL(string: rawHref, relativeTo: base)?.absoluteURL,
              let hrefOrigin = TransportOrigin(url: resolved),
              hrefOrigin == root.origin else {
            throw TransportError.pathEscapesRoot
        }
        guard let candidatePath = percentEncodedPath(of: resolved),
              let normalized = normalizedPath(candidatePath) else {
            throw TransportError.pathEscapesRoot
        }
        guard isWithinRoot(normalized, root: root.path) else {
            throw TransportError.pathEscapesRoot
        }
        return normalized
    }

    /// Extracts a URL's path **preserving a trailing slash** when present.
    /// `URL.path` itself silently drops a trailing slash (a long-standing
    /// Foundation quirk — `URL(string: "https://h/a/b/")!.path == "/a/b"`),
    /// which would corrupt the collection-vs-member distinction this module
    /// relies on. `URLComponents.path` does not have that problem, so it is
    /// used here instead of `url.path` directly.
    static func normalizedPath(of url: URL) -> String? {
        guard let encodedPath = percentEncodedPath(of: url) else { return nil }
        return normalizedPath(encodedPath)
    }

    private static func percentEncodedPath(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        return components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }

    /// `true` when `path` is equal to `rootPath` or nested under it.
    /// Purely a string-prefix check on already-`..`-free, decoded,
    /// slash-collapsed paths — safe because ``normalizedPath(_:)`` has
    /// already ruled out traversal segments.
    static func isWithinRoot(_ path: String, root rootPath: String) -> Bool {
        let trimmedRoot = rootPath.hasSuffix("/") && rootPath != "/" ? String(rootPath.dropLast()) : rootPath
        if trimmedRoot == "/" { return true }
        if path == trimmedRoot { return true }
        return path.hasPrefix(trimmedRoot + "/")
    }

    /// Whether a resolved entry path is the "self" entry of a `PROPFIND`
    /// (i.e. the collection that was queried, echoed back by the server
    /// alongside its children) rather than an actual child — such entries
    /// must be dropped before presenting a directory listing.
    public static func isSelfEntry(resolvedPath: String, requestPath: String) -> Bool {
        func trimTrailingSlash(_ value: String) -> String {
            value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
        }
        return trimTrailingSlash(resolvedPath) == trimTrailingSlash(requestPath)
    }
}
