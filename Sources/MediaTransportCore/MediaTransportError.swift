import Foundation

/// Protocol-neutral failures exposed by media transports.
///
/// Associated diagnostic text is intentionally omitted from `description`.
/// Adapters may retain a secret-safe reason for control flow without risking
/// accidental disclosure through logging.
public enum MediaTransportError: Error, Equatable, Sendable {
    case invalidInput(reason: String)
    case unsupportedCapability(String)
    case unsupportedRange(reason: String)
    case authentication(reason: String)
    case trust(reason: String)
    case permissionDenied
    case protocolViolation(reason: String)
    case timeout
    case resourceBusy
    case sourceChanged(reason: String)
    case cancelled
    case transport(code: Int)
}

extension MediaTransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidInput: return "invalidInput"
        case .unsupportedCapability: return "unsupportedCapability"
        case .unsupportedRange: return "unsupportedRange"
        case .authentication: return "authentication"
        case .trust: return "trust"
        case .permissionDenied: return "permissionDenied"
        case .protocolViolation: return "protocolViolation"
        case .timeout: return "timeout"
        case .resourceBusy: return "resourceBusy"
        case .sourceChanged: return "sourceChanged"
        case .cancelled: return "cancelled"
        case .transport(let code): return "transport(code: \(code))"
        }
    }
}
