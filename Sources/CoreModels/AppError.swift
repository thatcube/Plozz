import Foundation

/// The single error type surfaced to feature/UI code.
///
/// Provider and networking layers translate their low-level failures into one
/// of these cases so the UI can render consistent, friendly states without
/// knowing about HTTP status codes or `URLError`.
public enum AppError: Error, Equatable, Sendable {
    /// Could not reach the server (offline, DNS, timeout, refused).
    case serverUnreachable
    /// Server reachable but returned an unexpected/invalid response.
    case invalidResponse
    /// Credentials/token rejected (HTTP 401/403). Triggers re-auth.
    case unauthorized
    /// Username/password sign-in was rejected by the server.
    case invalidCredentials
    /// The requested resource does not exist (HTTP 404).
    case notFound
    /// Quick Connect is disabled on the server.
    case quickConnectUnavailable
    /// The Quick Connect code expired before the user approved it.
    case quickConnectExpired
    /// The operation was cancelled by the user.
    case cancelled
    /// A decoding/encoding problem.
    case decoding
    /// Anything else, with a non-sensitive message.
    case unknown(String)

    /// A short, user-facing message safe to display on tvOS.
    public var userMessage: String {
        switch self {
        case .serverUnreachable:
            return "Can’t reach the server. Check that it’s online and on the same network."
        case .invalidResponse:
            return "The server sent an unexpected response."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .invalidCredentials:
            return "Incorrect username or password. Please try again."
        case .notFound:
            return "We couldn’t find what you were looking for."
        case .quickConnectUnavailable:
            return "Quick Connect is turned off on this server. Enable it in the Jellyfin dashboard."
        case .quickConnectExpired:
            return "The code expired. Request a new one to continue."
        case .cancelled:
            return "Cancelled."
        case .decoding:
            return "We couldn’t read the server’s response."
        case .unknown:
            return "Something went wrong. Please try again."
        }
    }
}
