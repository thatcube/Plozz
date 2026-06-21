import Foundation

/// Pure decision logic for the Plex.tv PIN-link handshake.
///
/// The transport (`PlexAuthClient`) issues a PIN and polls it; this enum decides
/// what a poll result means so the rule is unit-testable without networking:
/// a PIN is *claimed* once it carries a non-empty `authToken`, otherwise it's
/// still *pending* the user entering the code at plex.tv/link.
public enum PlexPinFlow {
    public enum Outcome: Equatable, Sendable {
        /// The user hasn't linked the code yet — keep polling.
        case pending
        /// The code was linked; `authToken` is the account token.
        case claimed(authToken: String)
    }

    /// Evaluates a polled PIN. A whitespace-only or empty token counts as
    /// pending so a server that returns `""` rather than `null` is handled.
    static func evaluate(pin: PlexPinDTO) -> Outcome {
        guard let token = pin.authToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .pending
        }
        return .claimed(authToken: token)
    }
}
