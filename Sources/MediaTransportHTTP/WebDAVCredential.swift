import Foundation

/// The HTTP authentication scheme a password credential is permitted to
/// answer. Mirrors `URLAuthenticationChallenge.protectionSpace.authenticationMethod`
/// (`NSURLAuthenticationMethodHTTPBasic` / `...HTTPDigest`), abstracted so the
/// policy type doesn't need to import platform-specific constants.
public enum PasswordChallengeScheme: String, Sendable, CaseIterable {
    case basic
    case digest
}

/// Immutable policy for which HTTP challenge scheme(s) a password credential
/// may answer. Fixed at credential-construction time — never mutated after
/// the fact — so a caller can't be silently downgraded from Digest to Basic
/// mid-session by a server that starts sending a different challenge.
///
/// Three named cases rather than a free-form option set, so the choice is
/// explicit and auditable in call sites and code review:
///  - `.digestOnly` — the strictest: only ever answers a Digest challenge.
///    A Basic challenge is refused outright (fails closed, surfaced as
///    ``TransportError/authenticationSchemeNotPermitted(scheme:)``).
///  - `.basicAllowed` — an explicit, reviewed opt-in that Basic is acceptable
///    for this credential (in addition to Digest). Use this when the
///    maintainer/user has consciously decided Basic is fine for a given
///    server (still gated by the HTTPS-only rule below regardless).
///  - `.automatic` — no manual restriction stated; answers whichever single
///    scheme the server challenges with. Functionally equivalent to
///    `.basicAllowed` today, but recorded separately so future policy
///    changes (e.g. tightening the *default* to Digest-only) don't have to
///    silently reinterpret an explicit `.basicAllowed` choice a caller made.
///
/// None of this replaces the transport-wide rule that **any** reusable
/// password credential requires HTTPS — see ``CredentialPreflight``. This
/// type only decides which challenge scheme(s) are acceptable once HTTPS is
/// already established.
public struct PasswordAuthPolicy: Sendable, Equatable {
    public let acceptedSchemes: Set<PasswordChallengeScheme>
    private let label: String

    private init(acceptedSchemes: Set<PasswordChallengeScheme>, label: String) {
        self.acceptedSchemes = acceptedSchemes
        self.label = label
    }

    public static let automatic = PasswordAuthPolicy(
        acceptedSchemes: [.digest, .basic],
        label: "automatic"
    )
    public static let digestOnly = PasswordAuthPolicy(
        acceptedSchemes: [.digest],
        label: "digestOnly"
    )
    public static let basicAllowed = PasswordAuthPolicy(
        acceptedSchemes: [.digest, .basic],
        label: "basicAllowed"
    )

    public func permits(_ scheme: PasswordChallengeScheme) -> Bool {
        acceptedSchemes.contains(scheme)
    }
}

extension PasswordAuthPolicy: CustomStringConvertible {
    public var description: String { "PasswordAuthPolicy.\(label)" }
}

/// A WebDAV/HTTP credential. Deliberately **not** `Codable` — nothing that
/// can hold a secret in this module is ever serialized, to make "never put
/// credentials in ... Codable core models" structurally true rather than a
/// convention someone has to remember.
public enum WebDAVCredential: Sendable {
    case anonymous
    case password(username: String, password: String, policy: PasswordAuthPolicy)
    case bearerToken(String)
}

extension WebDAVCredential: CustomStringConvertible {
    /// Redacted description safe to log — never includes the password or
    /// token value.
    public var description: String {
        switch self {
        case .anonymous:
            return "WebDAVCredential.anonymous"
        case .password(_, _, let policy):
            return "WebDAVCredential.password(username: <redacted>, policy: \(policy), password: <redacted>)"
        case .bearerToken:
            return "WebDAVCredential.bearerToken(<redacted>)"
        }
    }
}

extension WebDAVCredential {
    func hasSameMaterial(as other: WebDAVCredential) -> Bool {
        switch (self, other) {
        case (.anonymous, .anonymous):
            return true
        case let (
            .password(lhsUsername, lhsPassword, lhsPolicy),
            .password(rhsUsername, rhsPassword, rhsPolicy)
        ):
            return lhsUsername == rhsUsername
                && lhsPassword == rhsPassword
                && lhsPolicy == rhsPolicy
        case let (.bearerToken(lhs), .bearerToken(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

/// Rejects any reusable credential against a cleartext origin **before** a
/// request is ever built or sent.
///
/// Rule: anonymous access is fine over plain HTTP (there's nothing to steal),
/// but a password or a static Bearer token must never be sent (or even
/// prepared to be sent) over a non-HTTPS origin — including LAN/private
/// endpoints, which are just as sniffable on a shared network as the public
/// internet.
public enum CredentialPreflight {
    /// Returns the rejection error if `credential` may not be used against
    /// `origin`, or `nil` if it's permitted.
    public static func validate(credential: WebDAVCredential, origin: TransportOrigin) -> TransportError? {
        switch credential {
        case .anonymous:
            return nil
        case .password:
            guard origin.isSecure else {
                return .cleartextCredentialRejected(
                    reason: "password credential requires HTTPS (origin \(origin.displayString) is not secure)"
                )
            }
            return nil
        case .bearerToken:
            guard origin.isSecure else {
                return .cleartextCredentialRejected(
                    reason: "bearer token requires HTTPS (origin \(origin.displayString) is not secure)"
                )
            }
            return nil
        }
    }
}
