import Foundation
import MediaTransportCore

/// How a media SFTP account authenticates. Mirrors the vault's `.sftp` policy:
/// password, or a generated private key (OpenSSH/PEM text). The transport never
/// sees a raw key file path — only in-memory material resolved from the vault.
public enum SFTPMediaTransportCredential: Sendable, Equatable {
    case password(username: String, password: String)
    case privateKey(username: String, privateKeyPEM: String)

    var username: String {
        switch self {
        case let .password(username, _): return username
        case let .privateKey(username, _): return username
        }
    }
}

/// The SSH host-key trust policy for one connection.
///
/// - `pinned`: the connection must present a host key whose SHA-256 matches these
///   32 bytes, else it fails closed with `.trust`. This is the only policy the
///   shipping adapter uses — the credential vault requires a host-key pin for
///   every `.sftp` account.
/// - `captureTrustOnFirstUse`: accept whatever host key is presented and record
///   its fingerprint for the caller to surface for approval. Used by the future
///   unified add-share UI's first-connect flow; never used to play back media.
public enum SFTPHostKeyPolicy: Sendable, Equatable {
    case pinned(sha256: [UInt8])
    case captureTrustOnFirstUse
}

/// Non-secret + secret connection material for one SFTP account, resolved per
/// (accountID, credentialRevision). The endpoint host/port/root come from the
/// session key; this carries only the credential and the host-key trust policy.
public struct SFTPMediaTransportConfiguration: Sendable, Equatable {
    public let credential: SFTPMediaTransportCredential
    public let hostKeyPolicy: SFTPHostKeyPolicy

    public init(credential: SFTPMediaTransportCredential, hostKeyPolicy: SFTPHostKeyPolicy) {
        self.credential = credential
        self.hostKeyPolicy = hostKeyPolicy
    }
}

/// A single directory entry as reported by the SFTP backend, before it is mapped
/// into a `RemoteFileEntry` (which enforces the transport-relative path rules).
struct SFTPBackendEntry: Sendable, Equatable {
    let name: String
    let kind: RemoteFileEntryKind
    let size: Int64?
    let modifiedAt: Date?

    init(name: String, kind: RemoteFileEntryKind, size: Int64?, modifiedAt: Date?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// An opaque, server-issued file handle. The bytes are meaningful only to the
/// server that produced them; the transport treats them as an opaque token.
struct SFTPFileHandle: Sendable, Equatable {
    let rawValue: [UInt8]
}

/// The seam every SFTP operation flows through. The real implementation
/// (`NIOSSHSFTPBackend`) drives Apple's swift-nio-ssh; tests substitute an
/// in-memory fake so the adapter / filesystem / byte-source logic runs
/// hermetically with no network — exactly how `MediaTransportSMB` stubs its
/// backend.
protocol SFTPTransportBackend: Sendable {
    /// Establishes the SSH transport, authenticates, opens the `sftp` subsystem,
    /// and negotiates the protocol version. Must enforce `hostKeyPolicy`.
    func connect(
        host: String,
        port: Int,
        credential: SFTPMediaTransportCredential,
        hostKeyPolicy: SFTPHostKeyPolicy
    ) async throws

    /// Canonicalizes a path against the server (`SSH_FXP_REALPATH`), used to
    /// resolve the configured root to an absolute server path.
    func realPath(_ path: String) async throws -> String

    func list(path: String) async throws -> [SFTPBackendEntry]
    func stat(path: String) async throws -> SFTPBackendEntry
    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data

    /// Opens a file for reading, returning its handle and the server-reported
    /// entry (from `FSTAT`) so the caller can revalidate the representation.
    func openFile(path: String) async throws -> (handle: SFTPFileHandle, entry: SFTPBackendEntry)

    /// Reads up to `length` bytes at `offset`. Implementations loop internally so
    /// a request larger than the server's per-`READ` limit still returns a
    /// contiguous chunk; a read at or past EOF returns empty data.
    func read(handle: SFTPFileHandle, offset: Int64, length: Int) async throws -> Data

    func closeFile(handle: SFTPFileHandle) async

    func shutdown() async
}
