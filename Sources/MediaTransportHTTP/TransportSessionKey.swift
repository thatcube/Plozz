import Foundation

/// The functional role a session is used for. Kept as its own key dimension
/// (rather than reusing the same session for both) so a background directory
/// scan and an active playback stream never share a keep-alive connection,
/// auth state, or cache — a stalled/slow scan can never starve or interfere
/// with a foreground playback read, and vice versa.
public enum TransportRole: String, Sendable, Hashable, CaseIterable {
    case scanner
    case playback
}

/// Every dimension a `URLSession` must be isolated by. Two requests that
/// differ in **any** field here must never share a session, its cookie jar,
/// its cache, its credential storage, or an underlying keep-alive
/// connection:
///
///  - `accountID` — a stable identifier for the configured share/account.
///    Different accounts (even pointed at the same server) never share
///    transport state.
///  - `credentialRevision` — a random UUID minted whenever the credential
///    changes (password rotated, re-authenticated, switched from anonymous
///    to authenticated, etc). Bumping it forces a brand-new session, so a
///    stale connection can never keep using credentials that were just
///    replaced or revoked.
///  - `origin` — exact scheme/host/port (see ``TransportOrigin``).
///  - `trustRevision` — a random UUID minted whenever the accepted TLS trust
///    changes (e.g. the user accepts a new self-signed leaf certificate).
///    Like `credentialRevision`, changing it invalidates any session that
///    was trusting the old cert.
///  - `role` — ``TransportRole``, so scanner and playback traffic never
///    share a session even for the same account/origin/trust.
public struct TransportSessionKey: Hashable, Sendable {
    public let accountID: String
    public let credentialRevision: UUID
    public let origin: TransportOrigin
    public let trustRevision: UUID
    public let role: TransportRole

    public init(
        accountID: String,
        credentialRevision: UUID,
        origin: TransportOrigin,
        trustRevision: UUID,
        role: TransportRole
    ) {
        self.accountID = accountID
        self.credentialRevision = credentialRevision
        self.origin = origin
        self.trustRevision = trustRevision
        self.role = role
    }
}

extension TransportSessionKey: CustomStringConvertible {
    /// Redacted description safe to log: account id + origin + role are
    /// operationally useful; the credential/trust revisions are opaque
    /// UUIDs (not secrets, but not meaningful on their own) and are included
    /// only as an id, never resolved back to a credential or certificate.
    public var description: String {
        "TransportSessionKey(account: \(accountID), origin: \(origin.displayString), role: \(role.rawValue), " +
        "credentialRevision: \(credentialRevision.uuidString), trustRevision: \(trustRevision.uuidString))"
    }
}
