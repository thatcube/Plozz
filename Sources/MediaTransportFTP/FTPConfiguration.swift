import CoreModels
import Foundation
import MediaTransportCore

/// The two URL schemes an FTP account can use. The adapter's
/// `transportIdentifier` is the scheme itself, so the shared
/// `MediaTransportResolverRegistry` routes on the account's real `ftp`/`ftps`
/// scheme and the session key that reaches the connection already carries a
/// valid endpoint — mirroring `WebDAVScheme`'s `http`/`https` split.
public enum FTPScheme: String, Sendable, CaseIterable {
    case ftp
    case ftps
}

/// How the FTP control + data channels are secured for one connection.
public enum FTPSecurity: Sendable, Equatable {
    /// Plaintext FTP — no transport encryption (credentials in the clear).
    case plaintext
    /// FTPS explicit: connect in the clear, then `AUTH TLS` + `PBSZ 0` +
    /// `PROT P` before login (RFC 4217). The modern default.
    case explicitTLS
    /// FTPS implicit: TLS from the first byte (conventionally port 990).
    case implicitTLS

    /// Whether the control channel is TLS-wrapped from connect (implicit) vs.
    /// upgraded after `AUTH TLS` (explicit) vs. never (plaintext).
    var isImplicitTLS: Bool { self == .implicitTLS }
    var negotiatesExplicitTLS: Bool { self == .explicitTLS }
    var usesTLS: Bool { self != .plaintext }
}

/// FTP login credential. FTP supports only anonymous or username/password.
public enum FTPCredential: Sendable, Equatable {
    case anonymous
    case password(username: String, password: String)

    /// The `USER`/`PASS` pair actually sent. Anonymous logs in as the
    /// conventional `anonymous` account with an opaque e-mail-style password.
    var loginPair: (user: String, pass: String) {
        switch self {
        case .anonymous:
            return ("anonymous", "anonymous@plozz")
        case let .password(username, password):
            let user = username.isEmpty ? "anonymous" : username
            return (user, password)
        }
    }
}

/// Non-secret + secret connection material for one FTP account, resolved per
/// (accountID, credentialRevision). Carries only what the endpoint can't: the
/// credential, the security policy, and the TLS trust policy.
public struct FTPMediaTransportConfiguration: Sendable, Equatable {
    public let credential: FTPCredential
    public let security: FTPSecurity
    public let trustPolicy: FTPTrustPolicy

    public init(
        credential: FTPCredential,
        security: FTPSecurity,
        trustPolicy: FTPTrustPolicy = .system
    ) {
        self.credential = credential
        self.security = security
        self.trustPolicy = trustPolicy
    }
}

/// TLS trust policy for an FTPS connection. Mirrors the WebDAV adapter's
/// system-vs-pinned-leaf split so a self-signed FTPS server can be pinned by
/// its exact leaf certificate SHA-256.
public enum FTPTrustPolicy: Sendable, Equatable {
    case system
    case pinnedLeaf(sha256: [UInt8], revision: UUID)
}

/// Resolves per-account FTP credentials/security/trust. **Must throw a
/// ``MediaTransportError``** (e.g. `.authentication` for a missing/incompatible
/// vault envelope), never a raw vault error — `ShareTransportBrowser` treats a
/// non-`MediaTransportError` as transient and would retry-loop on a permanent
/// credential problem.
public typealias FTPMediaTransportConfigurationProvider =
    @Sendable (String, CredentialRevision) throws -> FTPMediaTransportConfiguration
