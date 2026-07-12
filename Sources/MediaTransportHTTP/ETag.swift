import Foundation

/// A parsed HTTP `ETag` value (RFC 7232 §2.3).
///
/// Only a **strong** ETag is a valid range/seek validator — a weak ETag
/// (`W/"..."`) is explicitly allowed to represent semantically-equivalent
/// but byte-different content, so it cannot guarantee a `Range` read lines
/// up with what was probed.
public struct ETag: Equatable, Sendable {
    public let opaqueTag: String
    public let isWeak: Bool

    /// The exact `ETag` header value this was parsed from, useful for
    /// building `If-Match` headers without re-serializing.
    public let rawValue: String

    /// Parses a raw `ETag`/`If-Match`-style header value
    /// (`"abc123"` or `W/"abc123"`). Returns `nil` for anything that isn't
    /// syntactically a quoted entity tag (with or without the `W/` weak
    /// prefix) — including empty strings and unquoted garbage.
    public init?(headerValue raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var remainder = Substring(trimmed)
        var weak = false
        if remainder.hasPrefix("W/") {
            weak = true
            remainder = remainder.dropFirst(2)
        }

        guard remainder.count >= 2,
              remainder.first == "\"",
              remainder.last == "\"" else {
            return nil
        }
        let inner = remainder.dropFirst().dropLast()
        guard inner.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 0x21
                || (0x23...0x7E).contains(scalar.value)
                || scalar.value >= 0x80
        }) else {
            return nil
        }

        self.opaqueTag = String(inner)
        self.isWeak = weak
        self.rawValue = trimmed
    }

    /// `true` only for a syntactically valid **strong** tag — the sole kind
    /// this module will accept as a seekable-representation validator.
    public var isValidStrongValidator: Bool { !isWeak }
}
