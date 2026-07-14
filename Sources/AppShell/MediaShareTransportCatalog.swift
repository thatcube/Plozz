#if canImport(SwiftUI)
import Foundation
import CoreModels
import ProviderShare

/// How the user supplies a credential for a transport, as the unified onboarding
/// UI renders it. Deliberately smaller than the vault's `MediaShareAuthentication`
/// value space: the UI shows *controls*, and "leave it blank for guest/anonymous"
/// is a property of the `usernamePassword` control rather than a separate mode.
///
/// - `usernamePassword`: two fields; empty = guest/anonymous (SMB/FTP) or an
///   unauthenticated request (WebDAV). No separate "Anonymous" chooser.
/// - `token`: a single bearer-token field (WebDAV only, today).
///
/// SSH *key* auth is intentionally absent for now (it needs a "copy this public
/// key to your server" step that's clunky on tvOS); SFTP ships password-only and
/// key auth is a tracked open question.
enum MediaShareAuthMode: Equatable, Sendable {
    case usernamePassword
    case token
}

/// Which trust-on-first-use approval a transport requires, and whether it's
/// mandatory. Mirrors the two pin slots the vault's `MediaShareTrustMaterial`
/// already carries, so the one generic "Verify" screen can be driven by data.
enum MediaShareTrustKind: Equatable, Sendable {
    /// No fingerprint approval (SMB, NFS, plain FTP).
    case none
    /// TLS leaf certificate pin, only when the server isn't system-trusted
    /// (e.g. self-signed HTTPS). Optional — system-trusted servers skip it.
    case tlsLeafOnUntrusted
    /// SSH host-key pin, **required** on first connect (matches the vault rule
    /// that an SFTP credential must carry an `sshHostKeySHA256`).
    case sshHostKeyRequired
}

/// When to warn that a credential travels unencrypted.
enum PlaintextCredentialRisk: Equatable, Sendable {
    /// Never (the transport encrypts, or carries no credential).
    case never
    /// Only when the address resolves to an insecure scheme (WebDAV over `http`).
    case whenInsecureScheme
    /// Always when a credential is supplied (FTP is plaintext by nature).
    case always
}

/// One transport's *onboarding* metadata: everything the unified add-a-share flow
/// needs to render discovery, the credential form, and the trust screen — as
/// DATA, so SMB/WebDAV/NFS/SFTP/FTP are entries in a registry rather than five
/// bespoke screens. The network behaviours (probe, list-children) are supplied
/// separately by the flow model, because they need live backends; this type is
/// pure, `Sendable`, and unit-testable on its own.
///
/// Its `authModes`/`trust` are not new policy — they restate what
/// `MediaCredentialVault.validate()` already enforces, and a drift-guard test
/// keeps the two in lockstep.
struct TransportOnboardingDescriptor: Sendable {
    let kind: MediaShareTransportKind

    // MARK: Discovery
    /// Bonjour service type(s) this transport advertises as. Empty = not
    /// LAN-advertised (still reachable via a curated port sweep or manual entry).
    let bonjourServiceTypes: [String]
    /// Curated targets to confirm on an already-known host (Channel B). Each
    /// target carries a protocol-specific proof strategy; an open TCP port alone
    /// never becomes a detected transport label.
    let sweepTargets: [TransportSweepTarget]
    /// The port assumed when the user types none.
    let defaultPort: Int

    // MARK: Authenticate
    /// Credential controls to show, in order. Empty = no sign-in (NFS).
    let authModes: [MediaShareAuthMode]
    /// Whether leaving username + password blank is valid (guest/anonymous).
    /// SMB and WebDAV allow it; SFTP does not (SSH requires a username), so its
    /// form must require a username before Connect is enabled.
    let allowsBlankGuest: Bool
    let plaintextCredentialRisk: PlaintextCredentialRisk

    // MARK: Approve trust
    let trust: MediaShareTrustKind

    // MARK: Presentation
    /// Whether this transport lists *shares* (SMB) or *folders* (everything else)
    /// at the pick-location step. Both are "list children of a path"; this only
    /// picks the label.
    let listsSharesNotFolders: Bool

    /// Whether the transport has a real onboarding backend yet. `false` transports
    /// (NFS/SFTP today) appear in discovery and the form but are dummy-wired: the
    /// flow surfaces a "coming soon" notice instead of doing live I/O, until the
    /// owning transport branch merges here.
    let isImplemented: Bool
}

/// The single registry the unified onboarding flow consults. Composed here (the
/// same layer that builds `MediaShareRouteDetector`) so detection, discovery,
/// auth, and trust all stay in lockstep and a new transport is registered once.
///
/// FTP is intentionally absent: `MediaShareTransportKind` has no `.ftp` case yet,
/// and whether FTP is on the roadmap is an open question. Adding it later is a
/// descriptor entry + an enum case + a vault rule — no new screens.
enum MediaShareTransportCatalog {
    static let all: [TransportOnboardingDescriptor] = [
        TransportOnboardingDescriptor(
            kind: .smb,
            bonjourServiceTypes: ["_smb._tcp"],
            // SMB is trusted when advertised via `_smb._tcp`. Do not infer SMB
            // from an open socket until a real SMB negotiate probe exists.
            sweepTargets: [],
            defaultPort: 445,
            authModes: [.usernamePassword],
            allowsBlankGuest: true,
            plaintextCredentialRisk: .never,
            trust: .none,
            listsSharesNotFolders: true,
            isImplemented: true
        ),
        TransportOnboardingDescriptor(
            kind: .webDAV,
            bonjourServiceTypes: ["_webdav._tcp", "_webdavs._tcp"],
            // Protocol ports + Synology/QNAP defaults + common alt-HTTP + the
            // Unraid WebDAV app default. Every response must carry DAV-specific
            // evidence; generic NAS web UIs are rejected.
            sweepTargets: [
                TransportSweepTarget(port: 80, probe: .webDAVHTTP),
                TransportSweepTarget(port: 443, probe: .webDAVHTTPS),
                TransportSweepTarget(port: 5005, probe: .webDAVHTTP),
                TransportSweepTarget(port: 5006, probe: .webDAVHTTPS),
                TransportSweepTarget(port: 8080, probe: .webDAVHTTP),
                TransportSweepTarget(port: 8443, probe: .webDAVHTTPS),
                TransportSweepTarget(port: 8000, probe: .webDAVHTTP),
                TransportSweepTarget(port: 8888, probe: .webDAVHTTP),
                TransportSweepTarget(port: 8384, probe: .webDAVHTTP),
            ],
            defaultPort: 443,
            authModes: [.usernamePassword, .token],
            allowsBlankGuest: true,
            plaintextCredentialRisk: .whenInsecureScheme,
            trust: .tlsLeafOnUntrusted,
            listsSharesNotFolders: false,
            isImplemented: true
        ),
        TransportOnboardingDescriptor(
            kind: .nfs,
            bonjourServiceTypes: ["_nfs._tcp"],
            // Do not infer NFS from an open 2049 socket until an RPC/NFS probe
            // lands with the NFS transport branch.
            sweepTargets: [],
            defaultPort: 2049,
            authModes: [],
            allowsBlankGuest: false,
            plaintextCredentialRisk: .never,
            trust: .none,
            listsSharesNotFolders: false,
            isImplemented: false
        ),
        TransportOnboardingDescriptor(
            kind: .sftp,
            bonjourServiceTypes: ["_sftp-ssh._tcp"],
            sweepTargets: [
                TransportSweepTarget(port: 22, probe: .sshBanner),
            ],
            defaultPort: 22,
            authModes: [.usernamePassword],
            allowsBlankGuest: false,
            plaintextCredentialRisk: .never,
            trust: .sshHostKeyRequired,
            listsSharesNotFolders: false,
            isImplemented: false
        ),
    ]

    static func descriptor(for kind: MediaShareTransportKind) -> TransportOnboardingDescriptor? {
        all.first { $0.kind == kind }
    }

    /// Transports shown in discovery/onboarding, media-sensible order: native
    /// filesystem protocols first (better random-access seeking for large video,
    /// most common), then HTTP/SSH transports. Drives the default protocol pick
    /// when a device exposes several doors — a default, not an editorial badge.
    static let preferenceOrder: [MediaShareTransportKind] = [.smb, .nfs, .webDAV, .sftp]

    /// The best default door among a set of detected transports.
    static func preferredKind(among kinds: [MediaShareTransportKind]) -> MediaShareTransportKind? {
        preferenceOrder.first { kinds.contains($0) } ?? kinds.first
    }
}
#endif
