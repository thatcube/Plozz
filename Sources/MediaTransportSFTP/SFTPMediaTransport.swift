import CoreModels
import Foundation
import MediaTransportCore

/// Resolves per-account SFTP credentials/trust. **Must throw a
/// ``MediaTransportError``** (never a raw vault error) so `ShareTransportBrowser`
/// treats a permanent credential/trust problem as terminal rather than
/// retry-looping on it — the same contract the WebDAV provider documents.
public typealias SFTPMediaTransportConfigurationProvider =
    @Sendable (String, CredentialRevision) throws -> SFTPMediaTransportConfiguration

/// SFTP `MediaTransportAdapter`. Mirrors `SMBMediaTransportAdapter`: a stateless
/// struct whose `connect` produces a session owning one SSH connection (with the
/// `sftp` subsystem), so shutting one session down never disturbs another
/// account/role.
public struct SFTPMediaTransportAdapter: MediaTransportAdapter, Sendable {
    public let transportIdentifier = MediaShareTransportKind.sftp.rawValue

    private let configurationProvider: SFTPMediaTransportConfigurationProvider
    private let backendFactory: @Sendable () -> any SFTPTransportBackend

    public init(configurationProvider: @escaping SFTPMediaTransportConfigurationProvider) {
        self.init(
            configurationProvider: configurationProvider,
            backendFactory: { NIOSSHSFTPBackend() }
        )
    }

    /// DI seam: tests inject a `backendFactory` returning an in-memory fake so the
    /// full connect/list/stat/read/openSource path runs offline.
    init(
        configurationProvider: @escaping SFTPMediaTransportConfigurationProvider,
        backendFactory: @escaping @Sendable () -> any SFTPTransportBackend
    ) {
        self.configurationProvider = configurationProvider
        self.backendFactory = backendFactory
    }

    public func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        guard key.endpoint.transportIdentifier == transportIdentifier else {
            throw MediaTransportError.unsupportedCapability("transport")
        }
        let target = try SFTPConnectionTarget(endpoint: key.endpoint)

        // The provider owns the MediaTransportError contract; its errors propagate
        // unchanged so a permanent credential/trust failure stays terminal.
        let configuration = try configurationProvider(key.accountID, key.credentialRevision)

        let backend = backendFactory()
        let resolvedRoot: String
        do {
            try await backend.connect(
                host: target.host,
                port: target.port,
                credential: configuration.credential,
                hostKeyPolicy: configuration.hostKeyPolicy
            )
            // Canonicalize the configured root once so every subsequent path is
            // anchored to a real absolute server path.
            resolvedRoot = try SFTPPathPolicy.normalizedAbsoluteRoot(
                await backend.realPath(target.rootPath)
            )
        } catch {
            await backend.shutdown()
            throw mapSFTPError(error)
        }

        let fileSystem = SFTPMediaTransportFileSystem(
            backend: backend,
            rootPath: resolvedRoot,
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        return SFTPMediaTransportSession(key: key, fileSystem: fileSystem, backend: backend)
    }
}

/// The credential-free connection coordinates for one SFTP endpoint. SFTP has no
/// "share" concept (unlike SMB) — the root is simply an absolute server path.
struct SFTPConnectionTarget: Sendable {
    let host: String
    let port: Int
    let rootPath: String

    init(endpoint: MediaTransportEndpointIdentity) throws {
        guard !endpoint.host.isEmpty,
              endpoint.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP endpoint")
        }
        host = endpoint.host
        port = endpoint.port ?? 22
        rootPath = endpoint.rootPath.isEmpty ? "/" : endpoint.rootPath
    }
}

final class SFTPMediaTransportSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let backend: any SFTPTransportBackend

    init(
        key: MediaTransportSessionKey,
        fileSystem: any MediaTransportFileSystem,
        backend: any SFTPTransportBackend
    ) {
        self.key = key
        self.fileSystem = fileSystem
        self.backend = backend
    }

    func shutdown() async {
        await backend.shutdown()
    }
}

final class SFTPMediaTransportFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    static let maximumSmallFileSize = 16 * 1_024 * 1_024

    private let backend: any SFTPTransportBackend
    private let rootPath: String
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        backend: any SFTPTransportBackend,
        rootPath: String,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.backend = backend
        self.rootPath = rootPath
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func validate() async throws {
        do {
            _ = try await backend.list(path: rootPath)
        } catch {
            throw mapSFTPError(error)
        }
    }

    func probe() async throws -> MediaTransportProbe {
        // Transport-level capabilities only. Per-file seekability is proven at
        // `openSource` with a real ranged read, not asserted here — a file the
        // server won't serve at an offset is rejected there, not falsely
        // advertised as seekable.
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
        let normalizedPath = try SFTPPathPolicy.normalizedRelative(relativePath, allowEmpty: true)
        let path = absolutePath(forRelative: normalizedPath)
        do {
            return try await backend.list(path: path).compactMap { entry in
                guard entry.name != ".", entry.name != ".." else { return nil }
                let childPath = normalizedPath.isEmpty
                    ? entry.name
                    : "\(normalizedPath)/\(entry.name)"
                // Skip an entry whose name can't form a valid transport-relative
                // path (e.g. embedded slash/NUL) rather than aborting the scan.
                return try? RemoteFileEntry(
                    relativePath: childPath,
                    kind: entry.kind,
                    size: entry.kind == .directory ? nil : entry.size,
                    modifiedAt: entry.modifiedAt
                )
            }
        } catch {
            throw mapSFTPError(error)
        }
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let normalizedPath = try SFTPPathPolicy.normalizedRelative(relativePath)
        do {
            let entry = try await backend.stat(path: absolutePath(forRelative: normalizedPath))
            return try RemoteFileEntry(
                relativePath: normalizedPath,
                kind: entry.kind,
                size: entry.kind == .directory ? nil : entry.size,
                modifiedAt: entry.modifiedAt
            )
        } catch {
            throw mapSFTPError(error)
        }
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumSmallFileSize else {
            throw MediaTransportError.invalidInput(reason: "invalid small-file bound")
        }
        let normalizedPath = try SFTPPathPolicy.normalizedRelative(relativePath)
        do {
            return try await backend.readSmallFile(
                path: absolutePath(forRelative: normalizedPath),
                maximumBytes: maximumBytes
            )
        } catch {
            throw mapSFTPError(error)
        }
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        guard locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else {
            throw MediaTransportError.invalidInput(reason: "locator session mismatch")
        }
        // SFTP seek-safety rests on size + mtime (there is no ETag), so a
        // representation captured with any weaker identity cannot be revalidated
        // and is not playable (it still lists/stats fine).
        guard locator.representation.identity.kind == .modificationTime else {
            throw MediaTransportError.unsupportedRange(
                reason: "SFTP playback requires a modification-time representation"
            )
        }
        let normalizedPath = try SFTPPathPolicy.normalizedRelative(locator.relativePath)
        let path = absolutePath(forRelative: normalizedPath)

        // Containment: `OPEN`/`STAT` follow symlinks (leaf and intermediate), so a
        // path lexically under the root could still resolve to a file outside it.
        // Canonicalize with `REALPATH` and require the result to stay within the
        // configured root before opening — fail closed on any escape.
        try await withMappedSFTPError {
            let resolved = try SFTPPathPolicy.normalizedAbsoluteRoot(await backend.realPath(path))
            guard SFTPPathPolicy.isWithinRoot(resolved, root: rootPath) else {
                throw MediaTransportError.permissionDenied
            }
        }

        let opened = try await withMappedSFTPError {
            try await backend.openFile(path: path)
        }
        do {
            try validateSFTPRepresentation(opened.entry, against: locator.representation)
            guard let size = opened.entry.size else {
                throw MediaTransportError.sourceChanged(reason: "missing SFTP file size")
            }
            try await proveSeekability(handle: opened.handle, size: size)
            let source = SFTPByteSource(
                byteSize: size,
                backend: backend,
                handle: opened.handle,
                representation: locator.representation
            )
            return MediaTransportSourceLease(source: source)
        } catch {
            await backend.closeFile(handle: opened.handle)
            throw mapSFTPError(error)
        }
    }

    /// Fail-closed seekability proof: issue one real ranged `READ` at a non-zero
    /// offset (for any file large enough to have one) and require a byte back.
    /// This confirms the server honors offset-addressed reads before the source
    /// is advertised as seekable, rather than trusting the transport-level
    /// capability blindly.
    private func proveSeekability(handle: SFTPFileHandle, size: Int64) async throws {
        guard size >= 1 else { return }
        let probeOffset: Int64 = size >= 2 ? size - 1 : 0
        let data = try await backend.read(handle: handle, offset: probeOffset, length: 1)
        guard data.count == 1 else {
            throw MediaTransportError.unsupportedRange(reason: "SFTP server did not honor ranged read")
        }
    }

    private func absolutePath(forRelative relativePath: String) -> String {
        guard !relativePath.isEmpty else { return rootPath }
        guard rootPath != "/" else { return "/" + relativePath }
        return rootPath + "/" + relativePath
    }
}

/// Validates the currently-observed entry against the representation captured at
/// scan time. SFTP has no ETag, so identity is `size` + `mtime`; any drift means
/// the file changed underneath us and playback must fail closed.
func validateSFTPRepresentation(
    _ entry: SFTPBackendEntry,
    against representation: RemoteFileRepresentation
) throws {
    guard entry.kind == .file,
          entry.size == representation.size,
          representation.consistency == .changeDetecting,
          representation.identity.kind == .modificationTime,
          entry.modifiedAt == representation.identity.modifiedAt else {
        throw MediaTransportError.sourceChanged(reason: "SFTP representation changed")
    }
}

private func withMappedSFTPError<Value>(
    _ operation: () async throws -> Value
) async throws -> Value {
    do {
        return try await operation()
    } catch {
        throw mapSFTPError(error)
    }
}

/// Path normalization shared across the SFTP filesystem. Rejects traversal and
/// NUL, and canonicalizes the server-resolved root.
enum SFTPPathPolicy {
    static func normalizedRelative(_ path: String, allowEmpty: Bool = false) throws -> String {
        guard !path.contains("\0") else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP path")
        }
        let standardized = path.replacingOccurrences(of: "\\", with: "/")
        var normalized: [Substring] = []
        for component in standardized.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !normalized.isEmpty else {
                    throw MediaTransportError.invalidInput(reason: "SFTP path traversal")
                }
                normalized.removeLast()
            default:
                normalized.append(component)
            }
        }
        let result = normalized.joined(separator: "/")
        guard allowEmpty || !result.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "empty SFTP path")
        }
        return result
    }

    /// Normalizes an absolute server path (from `REALPATH`): must be absolute,
    /// NUL-free, traversal-free, and without a trailing slash (except root).
    static func normalizedAbsoluteRoot(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP root")
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != ".", component != ".." else {
                throw MediaTransportError.invalidInput(reason: "SFTP root traversal")
            }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// True when `absolutePath` (already `REALPATH`-canonicalized + normalized) is
    /// the configured root or lies strictly beneath it. Guards against a symlink
    /// resolving out of the share.
    static func isWithinRoot(_ absolutePath: String, root: String) -> Bool {
        if root == "/" { return absolutePath.hasPrefix("/") }
        return absolutePath == root || absolutePath.hasPrefix(root + "/")
    }
}
