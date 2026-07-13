import Foundation

/// One resource described in a `PROPFIND` multistatus response, after href
/// resolution/validation against the configured ``WebDAVRoot``.
public struct WebDAVEntry: Equatable, Sendable {
    /// Normalized, decoded, root-relative path (see ``WebDAVPathPolicy``).
    public let resolvedPath: String
    public let isCollection: Bool
    public let contentLength: Int64?
    public let lastModified: Date?
    public let etag: ETag?
    public let contentType: String?
}

/// Bounds on how much of a `PROPFIND` response this module will parse.
/// Exceeding either bound is a hard failure (``TransportError/responseTooLarge(limitBytes:)``
/// / ``TransportError/tooManyEntries(limit:)``) — never a silent partial
/// list, so a caller can't mistake a truncated directory for a complete one.
public struct PropfindParseLimits: Sendable {
    public let maxResponseBytes: Int
    public let maxEntries: Int

    public init(maxResponseBytes: Int, maxEntries: Int) {
        self.maxResponseBytes = max(0, maxResponseBytes)
        self.maxEntries = max(0, maxEntries)
    }

    /// 8 MiB / 5,000 entries — generous for any real directory listing while
    /// still bounding a hostile or buggy server's response.
    public static let `default` = PropfindParseLimits(maxResponseBytes: 8 * 1024 * 1024, maxEntries: 5_000)
}
