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
    /// The request conflicts with the server's current state (HTTP 409). For
    /// some endpoints — notably Trakt's `/scrobble` — a 409 means "already
    /// recorded" and is a *success*, so it is surfaced as a distinct case
    /// instead of the generic `.invalidResponse` so callers can treat it that way.
    case conflict
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

    /// Whether this represents a *transport-level* failure — we never reached a
    /// server that could give us a real answer (offline, DNS, TLS, timeout,
    /// connection refused), the request was cancelled, or the session token was
    /// rejected (which a re-auth will fix). It is **not** a definitive verdict
    /// about the resource.
    ///
    /// Used by the lyrics layer to decide whether a "no lyrics" outcome is
    /// trustworthy enough to cache: a `notFound`/`invalidResponse` from a
    /// reachable server is authoritative, but a `serverUnreachable` is just
    /// noise we must retry later rather than remember.
    public var isTransportFailure: Bool {
        switch self {
        case .serverUnreachable, .cancelled, .unauthorized:
            return true
        case .invalidResponse, .invalidCredentials, .notFound, .conflict,
             .quickConnectUnavailable, .quickConnectExpired, .decoding, .unknown:
            return false
        }
    }

    /// A short, user-facing message safe to display.
    ///
    /// `LocalizedStringResource` rather than `String` so these survive
    /// translation: a `String` reaching `Text` renders verbatim and is invisible
    /// to the String Catalog, which would leave every error message English
    /// forever. This is Foundation-only, so `CoreModels` stays a dependency-free
    /// leaf. Semantic keys because "Cancelled." is far too generic to key on.
    public var userMessage: LocalizedStringResource {
        switch self {
        case .serverUnreachable:
            return LocalizedStringResource(
                "error.serverUnreachable",
                defaultValue: "Can’t reach the server. Check that it’s online and on the same network.",
                comment: "Shown when the app cannot connect to the user's media server."
            )
        case .invalidResponse:
            return LocalizedStringResource(
                "error.invalidResponse",
                defaultValue: "The server sent an unexpected response.",
                comment: "Shown when the server replies with something the app cannot interpret."
            )
        case .unauthorized:
            return LocalizedStringResource(
                "error.unauthorized",
                defaultValue: "Your session has expired. Please sign in again.",
                comment: "Shown when the saved credentials are no longer accepted."
            )
        case .invalidCredentials:
            return LocalizedStringResource(
                "error.invalidCredentials",
                defaultValue: "Incorrect username or password. Please try again.",
                comment: "Shown when a sign-in attempt is rejected."
            )
        case .notFound:
            return LocalizedStringResource(
                "error.notFound",
                defaultValue: "We couldn’t find what you were looking for.",
                comment: "Shown when a requested item no longer exists on the server."
            )
        case .conflict:
            return LocalizedStringResource(
                "error.conflict",
                defaultValue: "The server already has a newer version of this.",
                comment: "Shown when a local change clashes with newer server data."
            )
        case .quickConnectUnavailable:
            return LocalizedStringResource(
                "error.quickConnectUnavailable",
                defaultValue: "Quick Connect is turned off on this server. Enable it in the Jellyfin dashboard.",
                comment: "Shown when Jellyfin's Quick Connect sign-in feature is disabled server-side."
            )
        case .quickConnectExpired:
            return LocalizedStringResource(
                "error.quickConnectExpired",
                defaultValue: "The code expired. Request a new one to continue.",
                comment: "Shown when the Quick Connect sign-in code timed out."
            )
        case .cancelled:
            return LocalizedStringResource(
                "error.cancelled",
                defaultValue: "Cancelled.",
                comment: "Shown when the user cancelled the operation."
            )
        case .decoding:
            return LocalizedStringResource(
                "error.decoding",
                defaultValue: "We couldn’t read the server’s response.",
                comment: "Shown when the server's response could not be parsed."
            )
        case .unknown:
            return LocalizedStringResource(
                "error.unknown",
                defaultValue: "Something went wrong. Please try again.",
                comment: "Generic fallback shown when no more specific error applies."
            )
        }
    }
}

/// Whether a failed identity check means the stored credential is actually bad.
///
/// Signing someone out is destructive and, for a tracker, unrecoverable without
/// a fresh OAuth round trip on a TV remote. Only the server saying "this
/// credential is rejected" justifies it. Anything else — offline, DNS, timeout,
/// a 500, a malformed body, a cancelled task — says nothing about the token, and
/// discarding it there turns a momentary network blip into a permanent sign-out.
public enum CredentialRejection {
    public static func discardsStoredCredential(_ error: Error) -> Bool {
        switch error {
        case let error as AppError:
            switch error {
            case .unauthorized, .invalidCredentials:
                return true
            case .serverUnreachable, .invalidResponse, .notFound, .conflict,
                 .quickConnectUnavailable, .quickConnectExpired, .cancelled,
                 .decoding, .unknown:
                return false
            }
        case is CancellationError:
            return false
        default:
            // An unclassified error is not evidence against the credential.
            return false
        }
    }
}
