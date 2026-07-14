import CoreModels
import Foundation
import MediaTransportCore
import TransportNFS

/// NFSv3 `MediaTransportAdapter`. Mirrors `SMBMediaTransportAdapter`: a stateless
/// struct whose `connect` mounts the export and produces a session that owns its
/// backend, so shutting one session down never disturbs another account/role.
///
/// The whole neutral machinery (scan/browse/enrich/search/Home/playback) works
/// unchanged once this adapter is registered under the `nfs` scheme — NFS
/// playback flows through the same `TransportIOReader` → `MediaTransportByteSource`
/// bridge the WebDAV/SMB transports use.
public struct NFSMediaTransportAdapter: MediaTransportAdapter, Sendable {
    public let transportIdentifier = MediaShareTransportKind.nfs.rawValue

    private let backendFactory: @Sendable () -> any NFSTransportBackend

    public init() {
        self.init(backendFactory: { NFSClientBackend() })
    }

    /// DI seam: tests inject a `backendFactory` returning a stubbed backend so
    /// the full connect/validate/list/stat/read/openSource path runs offline.
    init(backendFactory: @escaping @Sendable () -> any NFSTransportBackend) {
        self.backendFactory = backendFactory
    }

    public func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        guard key.endpoint.transportIdentifier == transportIdentifier else {
            throw MediaTransportError.unsupportedCapability("transport")
        }
        let target = try NFSConnectionTarget(endpoint: key.endpoint)

        let backend = backendFactory()
        do {
            try await backend.connect(
                host: target.host,
                exportPath: target.exportPath,
                nfsPort: target.nfsPort
            )
        } catch {
            await backend.shutdown()
            throw mapNFSError(error)
        }

        let fileSystem = NFSMediaTransportFileSystem(
            backend: backend,
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        return NFSMediaTransportSession(key: key, fileSystem: fileSystem, backend: backend)
    }
}

/// The credential-free connection target parsed from the endpoint identity. NFS
/// mounts the whole endpoint root path as the export (there is no SMB-style
/// share/path split — the server decides the export boundary), so relative paths
/// resolve under the mounted root handle.
private struct NFSConnectionTarget: Sendable {
    let host: String
    let exportPath: String
    /// Explicit nfsd port from `nfs://host:port`, if any (nil → resolve via
    /// portmap, falling back to 2049).
    let nfsPort: UInt16?

    init(endpoint: MediaTransportEndpointIdentity) throws {
        guard !endpoint.host.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "invalid NFS endpoint")
        }
        guard endpoint.rootPath.hasPrefix("/") else {
            throw MediaTransportError.invalidInput(reason: "invalid NFS export path")
        }
        host = endpoint.host
        exportPath = endpoint.rootPath
        nfsPort = endpoint.port.flatMap { UInt16(exactly: $0) }
    }
}

final class NFSMediaTransportSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let backend: any NFSTransportBackend

    init(
        key: MediaTransportSessionKey,
        fileSystem: any MediaTransportFileSystem,
        backend: any NFSTransportBackend
    ) {
        self.key = key
        self.fileSystem = fileSystem
        self.backend = backend
    }

    func shutdown() async {
        await backend.shutdown()
    }
}

final class NFSMediaTransportFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    static let maximumSmallFileSize = 16 * 1_024 * 1_024

    private let backend: any NFSTransportBackend
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        backend: any NFSTransportBackend,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.backend = backend
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func validate() async throws {
        do {
            try await backend.validate()
        } catch {
            throw mapNFSError(error)
        }
    }

    func probe() async throws -> MediaTransportProbe {
        // Transport-level capabilities. NFSv3 READ is random-access, mtime gives
        // change detection, and there is no ETag/If-Match, so per-file seek
        // safety rests on the stable file handle enforced at read time.
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: Self.maximumSmallFileSize,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        let normalizedPath = try Self.normalizedRelativePath(relativePath, allowEmpty: true)
        do {
            return try await backend.list(relativePath: normalizedPath).compactMap { entry in
                let childPath = normalizedPath.isEmpty
                    ? entry.name
                    : "\(normalizedPath)/\(entry.name)"
                return try RemoteFileEntry(
                    relativePath: childPath,
                    kind: entry.kind,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt
                )
            }
        } catch {
            throw mapNFSError(error)
        }
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let normalizedPath = try Self.normalizedRelativePath(relativePath)
        do {
            let entry = try await backend.stat(relativePath: normalizedPath)
            return try RemoteFileEntry(
                relativePath: normalizedPath,
                kind: entry.kind,
                size: entry.size,
                modifiedAt: entry.modifiedAt
            )
        } catch {
            throw mapNFSError(error)
        }
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumSmallFileSize else {
            throw MediaTransportError.invalidInput(reason: "invalid small-file bound")
        }
        let normalizedPath = try Self.normalizedRelativePath(relativePath)
        do {
            return try await backend.readSmallFile(
                relativePath: normalizedPath,
                maximumBytes: maximumBytes
            )
        } catch {
            throw mapNFSError(error)
        }
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        guard locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else {
            throw MediaTransportError.invalidInput(reason: "locator session mismatch")
        }
        let normalizedPath = try Self.normalizedRelativePath(locator.relativePath)
        do {
            let current = try await backend.stat(relativePath: normalizedPath)
            try Self.validateNFSRepresentation(current, against: locator.representation)
            let source = try await backend.openSource(
                relativePath: normalizedPath,
                representation: locator.representation
            )
            return MediaTransportSourceLease(source: source)
        } catch {
            throw mapNFSError(error)
        }
    }

    // MARK: - Helpers

    /// NFSv3 has no ETag; the representation identity is the modification time
    /// (see `ShareProvider.networkFileLocator`). This asserts the file still
    /// matches what the scan captured — the NFS parallel of SMB's
    /// `validateSMBRepresentation` and WebDAV's strong-ETag `If-Match`.
    static func validateNFSRepresentation(
        _ entry: NFSBackendEntry,
        against representation: RemoteFileRepresentation
    ) throws {
        guard entry.kind == .file,
              entry.size == representation.size,
              representation.consistency == .changeDetecting,
              representation.identity.kind == .modificationTime,
              entry.modifiedAt == representation.identity.modifiedAt else {
            throw MediaTransportError.sourceChanged(reason: "NFS representation changed since scan")
        }
    }

    /// Normalizes a transport-relative path and rejects traversal — defense in
    /// depth on top of the scanner's normalization, matching SMB's helper.
    static func normalizedRelativePath(
        _ path: String,
        allowEmpty: Bool = false
    ) throws -> String {
        guard !path.contains("\0") else {
            throw MediaTransportError.invalidInput(reason: "invalid NFS path")
        }
        let standardized = path.replacingOccurrences(of: "\\", with: "/")
        var normalized: [Substring] = []
        for component in standardized.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !normalized.isEmpty else {
                    throw MediaTransportError.invalidInput(reason: "NFS path traversal")
                }
                normalized.removeLast()
            default:
                normalized.append(component)
            }
        }
        let result = normalized.joined(separator: "/")
        guard allowEmpty || !result.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "empty NFS path")
        }
        return result
    }
}
