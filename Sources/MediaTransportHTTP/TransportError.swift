import Foundation

/// Typed error taxonomy for the WebDAV/HTTP transport feasibility spike.
///
/// Every case carries only diagnostic strings that are safe to log — none of
/// them may ever contain a credential, bearer token, or `Authorization`
/// header value. Callers building messages from server data (hrefs, header
/// values) must run them through ``redactedURLDescription(_:)`` first.
public enum TransportError: Error, Equatable, Sendable {
    // MARK: Origin / redirect
    case invalidOrigin(reason: String)
    case crossOriginRedirectRejected(from: String, to: String)
    case insecureRedirectDowngradeRejected(from: String, to: String)
    case tooManyRedirects(limit: Int)

    // MARK: Auth / credential policy
    /// A reusable credential (password or Bearer token) was supplied for a
    /// non-HTTPS origin. Rejected before any request is sent.
    case cleartextCredentialRejected(reason: String)
    /// The server challenged with an authentication scheme the caller's
    /// `PasswordAuthPolicy` does not permit (e.g. Basic offered, policy is
    /// `.digestOnly`).
    case authenticationSchemeNotPermitted(scheme: String)
    /// The server rejected the credential we supplied (401/403 after auth).
    case authenticationFailed(reason: String)
    /// A caller attempted to reuse one immutable session revision with
    /// different credential or trust material.
    case sessionConfigurationMismatch

    // MARK: TLS trust
    case trustEvaluationFailed(reason: String)
    /// The presented leaf certificate does not match the pinned SHA-256.
    case trustPinMismatch

    // MARK: WebDAV protocol / parsing
    case protocolError(status: Int, detail: String)
    case malformedMultistatus(reason: String)
    case responseTooLarge(limitBytes: Int)
    case tooManyEntries(limit: Int)
    /// An href in the multistatus response resolved outside the configured
    /// root or origin (path traversal / root escape).
    case pathEscapesRoot

    // MARK: Range / seek safety
    case rangeNotSupported(reason: String)
    /// The representation's GET ETag is missing or weak, so it cannot be
    /// used as a stable seek/range validator — browse-only.
    case seekableRequiresStrongETag
    /// The server's response to a validated bounded read didn't match what
    /// was requested (wrong status/Content-Range/body length/ETag).
    case rangeValidationFailed(reason: String)
    /// `412 Precondition Failed`, or an ETag mismatch discovered on a
    /// subsequent read — the underlying resource changed since it was probed.
    case sourceChanged(reason: String)

    // MARK: Misc
    case cancelled
    /// Underlying `URLSession` failure identified only by its numeric code.
    case transport(code: Int)
}

extension TransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidOrigin(let reason):
            return "invalidOrigin(\(reason))"
        case .crossOriginRedirectRejected(let from, let to):
            return "crossOriginRedirectRejected(from: \(from), to: \(to))"
        case .insecureRedirectDowngradeRejected(let from, let to):
            return "insecureRedirectDowngradeRejected(from: \(from), to: \(to))"
        case .tooManyRedirects(let limit):
            return "tooManyRedirects(limit: \(limit))"
        case .cleartextCredentialRejected(let reason):
            return "cleartextCredentialRejected(\(reason))"
        case .authenticationSchemeNotPermitted(let scheme):
            return "authenticationSchemeNotPermitted(\(scheme))"
        case .authenticationFailed(let reason):
            return "authenticationFailed(\(reason))"
        case .sessionConfigurationMismatch:
            return "sessionConfigurationMismatch"
        case .trustEvaluationFailed(let reason):
            return "trustEvaluationFailed(\(reason))"
        case .trustPinMismatch:
            return "trustPinMismatch"
        case .protocolError(let status, let detail):
            return "protocolError(status: \(status), \(detail))"
        case .malformedMultistatus(let reason):
            return "malformedMultistatus(\(reason))"
        case .responseTooLarge(let limitBytes):
            return "responseTooLarge(limitBytes: \(limitBytes))"
        case .tooManyEntries(let limit):
            return "tooManyEntries(limit: \(limit))"
        case .pathEscapesRoot:
            return "pathEscapesRoot"
        case .rangeNotSupported(let reason):
            return "rangeNotSupported(\(reason))"
        case .seekableRequiresStrongETag:
            return "seekableRequiresStrongETag"
        case .rangeValidationFailed(let reason):
            return "rangeValidationFailed(\(reason))"
        case .sourceChanged(let reason):
            return "sourceChanged(\(reason))"
        case .cancelled:
            return "cancelled"
        case .transport(let code):
            return "transport(code: \(code))"
        }
    }
}
