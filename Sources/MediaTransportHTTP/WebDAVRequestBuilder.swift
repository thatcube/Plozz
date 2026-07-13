import Foundation

/// The two permitted `Depth` values for a `PROPFIND` in this module.
/// `Infinity` is intentionally not representable — an unbounded recursive
/// listing against an arbitrary WebDAV server is a denial-of-service risk
/// (and plenty of servers refuse/mishandle it anyway); callers that need a
/// deeper tree walk must issue repeated `Depth: 1` requests themselves.
public enum PropfindDepth: String, Sendable {
    case zero = "0"
    case one = "1"
}

/// Builds the two WebDAV requests this module speaks: an `OPTIONS`
/// capability probe and a bounded `PROPFIND`. Pure request construction — no
/// I/O, so it's trivially unit-testable.
public enum WebDAVRequestBuilder {
    /// `OPTIONS` against `url`, used to sniff `DAV`/`Allow` capability
    /// headers before committing to treating a server as WebDAV-capable.
    public static func options(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// `PROPFIND` with an explicit, bounded `Depth` (never `Infinity`) and a
    /// minimal `allprop` body. `Accept-Encoding: identity` matches this
    /// module's range-safety requirement of never letting a transparent
    /// compressing proxy resize the body out from under a byte-accurate
    /// parse.
    public static func propfind(url: URL, depth: PropfindDepth) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(depth.rawValue, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:">
              <D:allprop/>
            </D:propfind>
            """.utf8
        )
        return request
    }

    /// A plain, unconditional `GET` used for a bounded whole-file read (small
    /// sidecar/metadata files). `Accept-Encoding: identity` keeps a transparent
    /// compressing proxy from resizing the body so the caller's byte cap and
    /// any length reasoning stay accurate.
    public static func get(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}
