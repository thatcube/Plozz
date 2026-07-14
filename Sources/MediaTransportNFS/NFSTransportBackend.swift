import CoreModels
import Foundation
import MediaTransportCore
import TransportNFS

/// One directory/file entry as seen by the NFS backend, before it is mapped to
/// the neutral ``RemoteFileEntry``.
struct NFSBackendEntry: Sendable, Equatable {
    let name: String
    let kind: RemoteFileEntryKind
    let size: Int64?
    let modifiedAt: Date?
}

/// The seam between the `MediaTransportCore` adapter and the pure-Swift
/// ``NFSClient``. Mirrors `SMBTransportBackend`: the real implementation talks to
/// a live mount, while tests inject a stub so the adapter/session/filesystem/
/// byte-source can be proven without a socket.
protocol NFSTransportBackend: Sendable {
    /// Resolves the mount (portmap → mountd → root handle) and opens the NFS
    /// channel. `nfsPort` overrides the nfsd port (explicit `nfs://host:port`).
    func connect(host: String, exportPath: String, nfsPort: UInt16?) async throws
    /// Proves the mounted root is a browsable directory.
    func validate() async throws
    func list(relativePath: String) async throws -> [NFSBackendEntry]
    func stat(relativePath: String) async throws -> NFSBackendEntry
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data
    /// Opens a random-access byte source on a dedicated connection. The
    /// representation carries the expected size + mtime the source revalidates
    /// on every read.
    func openSource(
        relativePath: String,
        representation: RemoteFileRepresentation
    ) async throws -> any MediaTransportByteSource
    func shutdown() async
}

/// Live NFS backend backed by ``NFSClient`` / ``NFSMountSession``. An `actor`
/// guards the single mount session it owns.
actor NFSClientBackend: NFSTransportBackend {
    private var session: NFSMountSession?

    func connect(host: String, exportPath: String, nfsPort: UInt16?) async throws {
        guard session == nil else {
            throw MediaTransportError.invalidInput(reason: "NFS backend already connected")
        }
        let client = NFSClient(host: host, nfsPort: nfsPort)
        session = try await client.mount(exportPath: exportPath)
    }

    func validate() async throws {
        let session = try requireSession()
        let attributes = try await session.rootAttributes()
        guard attributes.isDirectory else {
            throw MediaTransportError.protocolViolation(reason: "NFS export root is not a directory")
        }
    }

    func list(relativePath: String) async throws -> [NFSBackendEntry] {
        let session = try requireSession()
        let entries = try await session.list(relativePath: relativePath)
        return entries.compactMap { entry in
            guard let attributes = entry.attributes,
                  let kind = Self.remoteKind(attributes.type) else {
                return nil
            }
            return NFSBackendEntry(
                name: entry.name,
                kind: kind,
                size: kind == .directory ? nil : Int64(clamping: attributes.size),
                modifiedAt: attributes.modifiedAt
            )
        }
    }

    func stat(relativePath: String) async throws -> NFSBackendEntry {
        let session = try requireSession()
        let (_, attributes) = try await session.resolve(relativePath: relativePath)
        guard let kind = Self.remoteKind(attributes.type) else {
            throw MediaTransportError.unsupportedCapability("NFS file type")
        }
        return NFSBackendEntry(
            name: Self.lastComponent(of: relativePath),
            kind: kind,
            size: kind == .directory ? nil : Int64(clamping: attributes.size),
            modifiedAt: attributes.modifiedAt
        )
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        let session = try requireSession()
        let (handle, attributes) = try await session.resolve(relativePath: relativePath)
        guard attributes.isRegularFile else {
            throw MediaTransportError.invalidInput(reason: "NFS small-file target is not a file")
        }
        guard attributes.size <= UInt64(maximumBytes) else {
            throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
        }
        // A 0-byte file (empty .nfo/subtitle/playlist) is valid — return empty
        // rather than issuing a zero-length READ, matching the SMB/WebDAV contract.
        guard attributes.size > 0 else { return Data() }
        return try await session.read(handle: handle, offset: 0, length: Int(attributes.size))
    }

    func openSource(
        relativePath: String,
        representation: RemoteFileRepresentation
    ) async throws -> any MediaTransportByteSource {
        let session = try requireSession()
        let (handle, attributes) = try await session.resolve(relativePath: relativePath)
        guard attributes.isRegularFile else {
            throw MediaTransportError.invalidInput(reason: "NFS source target is not a file")
        }
        // NFS change detection is mtime-based (see ShareProvider.networkFileLocator);
        // the reader revalidates size + mtime on every read.
        guard representation.identity.kind == .modificationTime,
              let expectedModifiedAt = representation.identity.modifiedAt else {
            throw MediaTransportError.unsupportedRange(
                reason: "NFS playback requires a modification-time representation"
            )
        }
        let byteSize = representation.size
        // Each cursor opens its OWN reader (own connection) via this factory, so
        // cancelling one cursor never disturbs a sibling.
        let readerFactory: @Sendable () async throws -> NFSFileReader = {
            try await session.openReader(
                handle: handle,
                byteSize: byteSize,
                expectedModifiedAt: expectedModifiedAt
            )
        }
        return NFSByteSource(byteSize: byteSize, readerFactory: readerFactory)
    }

    func shutdown() async {
        await session?.shutdown()
        session = nil
    }

    private func requireSession() throws -> NFSMountSession {
        guard let session else {
            throw MediaTransportError.invalidInput(reason: "NFS backend not connected")
        }
        return session
    }

    /// Maps an NFS file type to the neutral kind. Symlinks and special files are
    /// dropped (return nil) — a read-only media share serves regular files and
    /// directories; following symlinks would need READLINK the client doesn't do.
    static func remoteKind(_ type: NFSFileType) -> RemoteFileEntryKind? {
        switch type {
        case .directory: return .directory
        case .regular: return .file
        case .symlink, .other: return nil
        }
    }

    private static func lastComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }
}

/// Maps ``NFSError`` (and stray errors) onto the neutral ``MediaTransportError``
/// vocabulary. A stale handle or a vanished file becomes `.sourceChanged`,
/// permission/auth problems stay terminal, and everything else degrades to a
/// transport/protocol fault — so `ShareTransportBrowser` never retry-loops on a
/// permanent failure.
func mapNFSError(_ error: Error) -> MediaTransportError {
    if let transportError = error as? MediaTransportError {
        return transportError
    }
    if error is CancellationError {
        return .cancelled
    }
    guard let nfsError = error as? NFSError else {
        return .transport(code: (error as NSError).code)
    }
    switch nfsError {
    case .connectionFailed:
        return .transport(code: -1)
    case .timeout:
        return .timeout
    case .cancelled:
        return .cancelled
    case .malformedResponse:
        return .protocolViolation(reason: "malformed NFS response")
    case .rpcDenied(let authError):
        return authError
            ? .authentication(reason: "NFS RPC credentials rejected")
            : .transport(code: -2)
    case .rpcUnsupported:
        // Permanent: the server accepted the call and rejected it on grounds
        // retrying can't fix (program/proc unavailable, version/args mismatch).
        return .unsupportedCapability("NFS RPC procedure")
    case .representationChanged:
        return .sourceChanged(reason: "NFS file changed since scan")
    case .invalidArgument:
        return .invalidInput(reason: "invalid NFS argument")
    case .status(let status):
        return mapNFSStatus(status)
    case .mountFailed(let status):
        switch status {
        case .accessDenied, .perm:
            // The most common cause on tvOS: the export requires a privileged
            // (reserved) source port the sandbox can't bind. Surfaced as a
            // permission failure the onboarding layer reports actionably.
            return .permissionDenied
        case .noEntry, .notDirectory:
            return .invalidInput(reason: "NFS export path not found")
        default:
            return .transport(code: -3)
        }
    }
}

private func mapNFSStatus(_ status: NFSStatus) -> MediaTransportError {
    switch status {
    case .ok:
        return .transport(code: 0)
    case .perm, .accessDenied:
        return .permissionDenied
    case .stale:
        return .sourceChanged(reason: "NFS file handle went stale")
    case .noEntry:
        return .sourceChanged(reason: "NFS file no longer exists")
    case .notDirectory, .isDirectory, .invalidArgument, .nameTooLong:
        return .invalidInput(reason: "invalid NFS path")
    case .notSupported:
        return .unsupportedCapability("NFS operation")
    case .io, .serverFault:
        return .transport(code: -4)
    case .other(let code):
        return .transport(code: Int(code))
    }
}
