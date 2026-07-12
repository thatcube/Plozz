import Foundation

/// Case-insensitive HTTP header helpers shared by the range/probe logic.
public enum HTTPHeaderUtilities {
    /// Normalizes `HTTPURLResponse.allHeaderFields` (`[AnyHashable: Any]`,
    /// case varies by server) into a lower-cased-key `[String: String]` for
    /// reliable lookup.
    public static func normalizedHeaders(from allHeaderFields: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            guard let keyString = key as? String else { continue }
            result[keyString.lowercased()] = "\(value)"
        }
        return result
    }

    /// Same normalization for an already-`[String: String]` header map
    /// (e.g. one built by hand in a test).
    public static func normalizedHeaders(from headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            result[key.lowercased()] = value
        }
        return result
    }
}

/// A parsed `Content-Range: bytes start-end/total` response header. A
/// missing or `*` (unknown) total is treated as unparsable — this module
/// requires an exact total on every bounded read, never an approximate one.
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    static func parse(_ value: String) -> ContentRange? {
        let unitAndRange = value.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard unitAndRange.count == 2,
              unitAndRange[0].lowercased() == "bytes" else {
            return nil
        }
        let remainder = unitAndRange[1]
        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] != "*", let total = Int64(parts[1]) else { return nil }

        let rangeParts = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeParts.count == 2, let start = Int64(rangeParts[0]), let end = Int64(rangeParts[1]) else {
            return nil
        }
        guard start >= 0, end >= start, end < total, total > 0 else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }
}

/// Result of successfully probing a resource for range/seek support.
public struct RangeProbeResult: Equatable, Sendable {
    public let etag: ETag
    public let totalLength: Int64
    public let resourceURL: URL

    public init(etag: ETag, totalLength: Int64, resourceURL: URL) {
        self.etag = etag
        self.totalLength = totalLength
        self.resourceURL = resourceURL
    }
}

/// Builds and validates the two request/response pairs a safe ranged read
/// needs: an initial 1-byte probe that establishes a strong `ETag` and the
/// resource's total length, and every subsequent bounded read, which must
/// reuse that exact `ETag` as an `If-Match` precondition.
///
/// All of this is pure request-building / response-validation logic with no
/// I/O, so it is exhaustively unit-testable against hand-built
/// status/header/body-length fixtures without a real server.
public enum RangeProbe {
    // MARK: - Probe (establishes seekability)

    /// `GET` with `Range: bytes=0-0` and `Accept-Encoding: identity`. No
    /// `If-Match` yet — this is the first request, before any validator is
    /// known.
    public static func probeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// Validates a probe response. Success requires: `206` (not `200` — a
    /// server that ignores `Range` and returns the whole body is not
    /// seekable by this module's definition), a syntactically valid
    /// **strong** `ETag`, a well-formed `Content-Range: bytes 0-0/<total>`,
    /// and a 1-byte body.
    public static func validateProbe(
        status: Int,
        headers: [String: String],
        bodyLength: Int,
        resourceURL: URL
    ) -> Result<RangeProbeResult, TransportError> {
        if status == 412 {
            return .failure(.sourceChanged(reason: "412 Precondition Failed during range probe"))
        }
        if status == 200 {
            return .failure(.rangeNotSupported(reason: "server returned 200 OK — ignored the Range request, not seekable"))
        }
        guard status == 206 else {
            return .failure(.rangeNotSupported(reason: "expected 206 Partial Content for probe, got \(status)"))
        }

        let normalized = HTTPHeaderUtilities.normalizedHeaders(from: headers)
        if let contentEncoding = normalized["content-encoding"],
           contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .failure(.rangeValidationFailed(reason: "range response used a content encoding"))
        }
        guard let etagHeader = normalized["etag"], let etag = ETag(headerValue: etagHeader) else {
            return .failure(.seekableRequiresStrongETag)
        }
        guard etag.isValidStrongValidator else {
            return .failure(.seekableRequiresStrongETag)
        }
        guard let contentRangeHeader = normalized["content-range"], let contentRange = ContentRange.parse(contentRangeHeader) else {
            return .failure(.rangeValidationFailed(reason: "missing/malformed Content-Range on probe"))
        }
        guard contentRange.start == 0, contentRange.end == 0 else {
            return .failure(.rangeValidationFailed(reason: "probe Content-Range did not echo bytes=0-0"))
        }
        guard bodyLength == 1 else {
            return .failure(.rangeValidationFailed(reason: "probe body length \(bodyLength) != 1"))
        }
        return .success(
            RangeProbeResult(
                etag: etag,
                totalLength: contentRange.total,
                resourceURL: resourceURL
            )
        )
    }

    // MARK: - Bounded reads

    /// Default cap on a single ranged read — generous for a playback chunk
    /// while still bounding a caller (or a confused server) from requesting
    /// an unbounded amount into memory at once.
    public static let defaultMaxReadBytes: Int64 = 64 * 1024 * 1024

    /// Builds a bounded-read request for the inclusive byte range
    /// `[start, end]`, gated on the exact strong `ETag` learned from the
    /// probe (`If-Match`). Validates the range arithmetic (no negative/
    /// inverted ranges, no overflow, no exceeding `maxReadBytes`) before
    /// returning a request — this is the "reject before execution" half of
    /// range safety.
    public static func readRequest(
        url: URL,
        start: Int64,
        end: Int64,
        ifMatch etag: ETag,
        maxReadBytes: Int64 = defaultMaxReadBytes
    ) -> Result<URLRequest, TransportError> {
        guard start >= 0, end >= start else {
            return .failure(.rangeValidationFailed(reason: "invalid range \(start)-\(end)"))
        }
        let (sizeMinusOne, subtractOverflowed) = end.subtractingReportingOverflow(start)
        if subtractOverflowed {
            return .failure(.rangeValidationFailed(reason: "range size arithmetic overflowed"))
        }
        let (size, addOverflowed) = sizeMinusOne.addingReportingOverflow(1)
        if addOverflowed {
            return .failure(.rangeValidationFailed(reason: "range size arithmetic overflowed"))
        }
        guard size <= maxReadBytes else {
            return .failure(.rangeValidationFailed(reason: "requested range size \(size) exceeds max \(maxReadBytes)"))
        }
        guard etag.isValidStrongValidator else {
            return .failure(.seekableRequiresStrongETag)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue(etag.rawValue, forHTTPHeaderField: "If-Match")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return .success(request)
    }

    /// Validates a bounded read's response against exactly what was
    /// requested. Every check is exact-match, not "close enough": status
    /// must be `206` (`200` is explicitly rejected), `Content-Range` must
    /// echo the requested start/end and the same total the probe saw, the
    /// `ETag` must be byte-identical to the one the probe pinned, and the
    /// body length must equal `end - start + 1`. `412`, a missing ETag, or
    /// an ETag that no longer matches all map to
    /// ``TransportError/sourceChanged(reason:)`` — the resource changed
    /// since it was probed, not a generic protocol failure.
    public static func validateRead(
        status: Int,
        headers: [String: String],
        bodyLength: Int,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotal: Int64,
        expectedETag: ETag
    ) -> Result<Void, TransportError> {
        if status == 412 {
            return .failure(.sourceChanged(reason: "412 Precondition Failed — resource changed since it was probed"))
        }
        if status == 200 {
            return .failure(.rangeValidationFailed(reason: "server returned 200 OK instead of 206 Partial Content for a ranged read"))
        }
        guard status == 206 else {
            return .failure(.rangeValidationFailed(reason: "expected 206 Partial Content, got \(status)"))
        }

        let normalized = HTTPHeaderUtilities.normalizedHeaders(from: headers)
        if let contentEncoding = normalized["content-encoding"],
           contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .failure(.rangeValidationFailed(reason: "range response used a content encoding"))
        }
        guard expectedETag.isValidStrongValidator else {
            return .failure(.seekableRequiresStrongETag)
        }
        guard let etagHeader = normalized["etag"], let etag = ETag(headerValue: etagHeader) else {
            return .failure(.sourceChanged(reason: "response carried no ETag to validate against the probe"))
        }
        guard etag.isValidStrongValidator else {
            return .failure(.sourceChanged(reason: "response ETag is no longer a strong validator"))
        }
        guard etag.rawValue == expectedETag.rawValue else {
            return .failure(.sourceChanged(reason: "ETag changed since the resource was probed"))
        }
        guard let contentRangeHeader = normalized["content-range"], let contentRange = ContentRange.parse(contentRangeHeader) else {
            return .failure(.rangeValidationFailed(reason: "missing/malformed Content-Range on bounded read"))
        }
        guard contentRange.start == expectedStart, contentRange.end == expectedEnd, contentRange.total == expectedTotal else {
            return .failure(
                .rangeValidationFailed(
                    reason: "Content-Range bytes \(contentRange.start)-\(contentRange.end)/\(contentRange.total) " +
                        "did not match requested bytes=\(expectedStart)-\(expectedEnd)/\(expectedTotal)"
                )
            )
        }
        guard expectedStart >= 0, expectedEnd >= expectedStart else {
            return .failure(.rangeValidationFailed(reason: "invalid expected range"))
        }
        let (sizeMinusOne, subtractOverflowed) = expectedEnd.subtractingReportingOverflow(expectedStart)
        let (expectedBodyLength, addOverflowed) = sizeMinusOne.addingReportingOverflow(1)
        guard !subtractOverflowed, !addOverflowed else {
            return .failure(.rangeValidationFailed(reason: "expected range size arithmetic overflowed"))
        }
        guard Int64(bodyLength) == expectedBodyLength else {
            return .failure(.rangeValidationFailed(reason: "body length \(bodyLength) != expected \(expectedBodyLength)"))
        }
        return .success(())
    }
}
