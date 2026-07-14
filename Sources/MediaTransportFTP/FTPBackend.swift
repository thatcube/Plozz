import CoreModels
import Foundation
import MediaTransportCore

/// One entry the FTP backend surfaces for a directory child or a `stat`.
/// For a *file* the transport re-derives an authoritative `size`/`modifiedAt`
/// via `SIZE`/`MDTM`; a directory carries no size.
struct FTPBackendEntry: Sendable, Equatable {
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

/// The protocol engine seam. The real implementation
/// (``FTPNetworkBackend``) speaks FTP over `NWConnection`; tests inject an
/// in-memory fake so the filesystem/adapter/byte-source layers run without a
/// socket — exactly mirroring `SMBTransportBackend`.
///
/// All paths passed in are absolute, root-anchored, traversal-checked server
/// paths (see ``FTPPathPolicy``).
protocol FTPBackend: Sendable {
    /// Opens the control channel, negotiates TLS (per the security policy),
    /// logs in, and prepares the session (`TYPE I`, UTF-8).
    func connect() async throws
    func list(path: String) async throws -> [FTPBackendEntry]
    func stat(path: String) async throws -> FTPBackendEntry
    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data
    /// Random-access read for playback. The backend restarts the transfer with
    /// `REST`+`RETR` on a discontiguous `offset` and continues an already-open
    /// stream on a contiguous one. `expected` is re-validated (SIZE) so a file
    /// that changed underneath playback fails with `.sourceChanged`.
    func read(
        path: String,
        at offset: Int64,
        length: Int,
        expected: RemoteFileRepresentation
    ) async throws -> Data
    func shutdown() async
}

/// Factory that creates + connects a fresh backend for one playback cursor,
/// so each cursor owns an isolated control+data channel (mirrors SMB's
/// per-cursor channel isolation).
typealias FTPBackendFactory = @Sendable () async throws -> any FTPBackend

/// Maps a raw backend/`NWConnection`/protocol error to the neutral
/// `MediaTransportError`. FTP reply-code semantics (RFC 959 §4.2):
/// 530/532 → auth, 550/553 → permission/unavailable, 4xx → transient.
func mapFTPError(_ error: Error) -> MediaTransportError {
    if let transportError = error as? MediaTransportError {
        return transportError
    }
    if error is CancellationError {
        return .cancelled
    }
    if let protocolError = error as? FTPProtocolError {
        switch protocolError {
        case .tlsRequired:
            return .trust(reason: "FTP server requires TLS")
        case .unexpectedReply(let code):
            return mapReplyCode(code)
        case .passiveModeUnavailable, .malformedPassiveResponse:
            return .protocolViolation(reason: "FTP passive mode failed")
        case .malformedReply, .malformedListing:
            return .protocolViolation(reason: "malformed FTP response")
        case .dataConnectionFailed:
            return .transport(code: -1)
        case .transferIncomplete:
            return .sourceChanged(reason: "FTP transfer ended early")
        }
    }
    return .transport(code: (error as NSError).code)
}

func mapReplyCode(_ code: Int) -> MediaTransportError {
    switch code {
    case 530, 532:
        return .authentication(reason: "FTP login failed")
    case 550, 553:
        return .permissionDenied
    case 421:
        return .timeout
    case 425, 426:
        return .transport(code: code)
    default:
        return .transport(code: code)
    }
}

/// Validates a freshly-observed file (size + mtime) against the representation
/// captured at scan time. FTP has no ETag, so change detection rests on
/// `SIZE` + `MDTM`, mirroring SMB's modification-time identity.
func validateFTPRepresentation(
    size: Int64,
    modifiedAt: Date?,
    against representation: RemoteFileRepresentation
) throws {
    guard size == representation.size,
          representation.consistency == .changeDetecting else {
        throw MediaTransportError.sourceChanged(reason: "FTP representation changed")
    }
    switch representation.identity.kind {
    case .modificationTime:
        // Require the mtime to match when the scan captured one.
        guard modifiedAt == representation.identity.modifiedAt else {
            throw MediaTransportError.sourceChanged(reason: "FTP mtime changed")
        }
    case .strongETag, .fileIdentifier, .snapshot:
        // FTP never produces these; a mismatch means a wiring bug upstream.
        throw MediaTransportError.sourceChanged(reason: "unexpected FTP identity")
    }
}
