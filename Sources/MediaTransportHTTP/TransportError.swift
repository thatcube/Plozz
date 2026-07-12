import Foundation

/// HTTP/WebDAV-specific failures retained inside the HTTP adapter boundary.
///
/// Associated diagnostic text is never included in `description`, because
/// callers may construct it from untrusted server responses.
public enum TransportError: Error, Equatable, Sendable {
    case invalidOrigin(reason: String)
    case crossOriginRedirectRejected(from: String, to: String)
    case insecureRedirectDowngradeRejected(from: String, to: String)
    case tooManyRedirects(limit: Int)
    case cleartextCredentialRejected(reason: String)
    case authenticationSchemeNotPermitted(scheme: String)
    case authenticationFailed(reason: String)
    case sessionConfigurationMismatch
    case trustEvaluationFailed(reason: String)
    case trustPinMismatch
    case protocolError(status: Int, detail: String)
    case malformedMultistatus(reason: String)
    case responseTooLarge(limitBytes: Int)
    case tooManyEntries(limit: Int)
    case pathEscapesRoot
    case rangeNotSupported(reason: String)
    case seekableRequiresStrongETag
    case rangeValidationFailed(reason: String)
    case sourceChanged(reason: String)
    case cancelled
    case transport(code: Int)
}

extension TransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidOrigin: return "invalidOrigin"
        case .crossOriginRedirectRejected: return "crossOriginRedirectRejected"
        case .insecureRedirectDowngradeRejected: return "insecureRedirectDowngradeRejected"
        case .tooManyRedirects(let limit): return "tooManyRedirects(limit: \(limit))"
        case .cleartextCredentialRejected: return "cleartextCredentialRejected"
        case .authenticationSchemeNotPermitted: return "authenticationSchemeNotPermitted"
        case .authenticationFailed: return "authenticationFailed"
        case .sessionConfigurationMismatch: return "sessionConfigurationMismatch"
        case .trustEvaluationFailed: return "trustEvaluationFailed"
        case .trustPinMismatch: return "trustPinMismatch"
        case .protocolError(let status, _): return "protocolError(status: \(status))"
        case .malformedMultistatus: return "malformedMultistatus"
        case .responseTooLarge(let limit): return "responseTooLarge(limitBytes: \(limit))"
        case .tooManyEntries(let limit): return "tooManyEntries(limit: \(limit))"
        case .pathEscapesRoot: return "pathEscapesRoot"
        case .rangeNotSupported: return "rangeNotSupported"
        case .seekableRequiresStrongETag: return "seekableRequiresStrongETag"
        case .rangeValidationFailed: return "rangeValidationFailed"
        case .sourceChanged: return "sourceChanged"
        case .cancelled: return "cancelled"
        case .transport(let code): return "transport(code: \(code))"
        }
    }
}
