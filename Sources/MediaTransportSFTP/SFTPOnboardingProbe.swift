import Foundation
import MediaTransportCore

/// The outcome of a first-connect SFTP onboarding probe.
public enum SFTPOnboardingProbeResult: Sendable, Equatable {
    /// The SSH handshake completed, the credentials authenticated, and the
    /// server's host key was captured. `hostKeySHA256` is the 32-byte SHA-256 of
    /// the presented host key, to surface for trust-on-first-use approval and to
    /// persist as the account's mandatory host-key pin.
    case success(hostKeySHA256: Data)
    /// The server was unreachable or the SSH handshake stalled/failed.
    case unreachable
    /// The credentials were rejected (auth failure).
    case authenticationFailed
    /// The server spoke SSH but something else went wrong (subsystem, protocol).
    case failed(String)
    /// The probe was cancelled.
    case cancelled
}

/// One browsable directory at the SFTP pick-location step.
public struct SFTPDirectoryItem: Sendable, Equatable {
    public let name: String
    /// Absolute, server-rooted path (the parent joined with `name`).
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// The outcome of listing an SFTP directory during onboarding.
public enum SFTPDirectoryListing: Sendable, Equatable {
    case success([SFTPDirectoryItem])
    case authenticationFailed
    case unreachable
    case failed(String)
    case cancelled
}

/// A testable seam for the SFTP add-share onboarding probe. The real
/// implementation drives a one-shot `.captureTrustOnFirstUse` SSH connect; tests
/// substitute a stub so the AppShell onboarding state machine runs offline.
///
/// Host-key capture deliberately uses a non-secret probe credential. SSH presents
/// its host key before user authentication, so onboarding can show and approve the
/// fingerprint without exposing the user's real password to an untrusted first
/// connection. The approved pinned reconnect performs real authentication.
public protocol SFTPOnboardingProbing: Sendable {
    func captureHostKey(
        host: String,
        port: Int
    ) async -> SFTPOnboardingProbeResult

    /// Lists the child directories of `path`, connecting `.pinned` to the
    /// already-approved host key so the user can drill into a subfolder to use as
    /// the share root. Reconnects per call — onboarding is low-frequency, and this
    /// mirrors the WebDAV browser's stateless per-request model.
    func listDirectories(
        host: String,
        port: Int,
        username: String,
        password: String,
        hostKeySHA256: Data,
        path: String
    ) async -> SFTPDirectoryListing
}

/// The production ``SFTPOnboardingProbing``: a one-shot `.captureTrustOnFirstUse`
/// connect over `NIOSSHSFTPBackend`, returning the captured host-key SHA-256. No
/// user credential is sent until the caller approves this key and reconnects
/// `.pinned`.
public struct SFTPOnboardingProbe: SFTPOnboardingProbing {
    public init() {}

    public func captureHostKey(
        host: String,
        port: Int
    ) async -> SFTPOnboardingProbeResult {
        let backend = NIOSSHSFTPBackend()
        defer { Task { await backend.shutdown() } }
        do {
            try await backend.connect(
                host: host,
                port: port,
                credential: .password(
                    username: "plozz-host-key-probe",
                    password: ""
                ),
                hostKeyPolicy: .captureTrustOnFirstUse
            )
        } catch {
            if let fingerprint = backend.capturedHostKeyFingerprint,
               fingerprint.count == 32 {
                return .success(hostKeySHA256: Data(fingerprint))
            }
            return Self.classify(error)
        }
        guard let fingerprint = backend.capturedHostKeyFingerprint, fingerprint.count == 32 else {
            // A successful connect under `.captureTrustOnFirstUse` must have
            // recorded a 32-byte SHA-256; its absence is a hard failure rather
            // than a silent fall-through to an unpinned save.
            return .failed("Couldn’t read this server’s host key.")
        }
        return .success(hostKeySHA256: Data(fingerprint))
    }

    public func listDirectories(
        host: String,
        port: Int,
        username: String,
        password: String,
        hostKeySHA256: Data,
        path: String
    ) async -> SFTPDirectoryListing {
        let backend = NIOSSHSFTPBackend()
        defer { Task { await backend.shutdown() } }
        do {
            try await backend.connect(
                host: host,
                port: port,
                credential: .password(username: username, password: password),
                hostKeyPolicy: .pinned(sha256: Array(hostKeySHA256))
            )
            let entries = try await backend.list(path: path)
            let base = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
            let items = entries
                .filter { $0.kind == .directory && $0.name != "." && $0.name != ".." }
                .map { SFTPDirectoryItem(name: $0.name, path: "\(base)/\($0.name)") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(items)
        } catch {
            switch Self.classify(error) {
            case .authenticationFailed: return .authenticationFailed
            case .unreachable: return .unreachable
            case .cancelled: return .cancelled
            case .failed(let reason): return .failed(reason)
            case .success: return .failed("Couldn’t list this folder.")
            }
        }
    }

    private static func classify(_ error: Error) -> SFTPOnboardingProbeResult {
        guard let transportError = error as? MediaTransportError else {
            return .failed("Couldn’t connect to this server.")
        }
        switch transportError {
        case .authentication, .permissionDenied:
            return .authenticationFailed
        case .cancelled:
            return .cancelled
        case .transport, .timeout, .resourceBusy:
            return .unreachable
        case .trust(let reason),
             .protocolViolation(let reason),
             .invalidInput(let reason),
             .unsupportedRange(let reason),
             .sourceChanged(let reason):
            return .failed(reason)
        case .unsupportedCapability(let reason):
            return .failed(reason)
        }
    }
}
