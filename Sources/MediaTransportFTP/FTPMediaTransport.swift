import CoreModels
import Foundation
import MediaTransportCore

/// Credential-free FTP connection target derived from the session key's
/// endpoint. Port defaults by security policy when the endpoint omits one:
/// implicit FTPS → 990, everything else → 21.
struct FTPConnectionTarget: Sendable, Equatable {
    let host: String
    let port: Int
    let rootPath: String

    init(endpoint: MediaTransportEndpointIdentity, security: FTPSecurity) throws {
        guard !endpoint.host.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "invalid FTP endpoint")
        }
        host = endpoint.host
        port = endpoint.port ?? (security.isImplicitTLS ? 990 : 21)
        rootPath = try FTPPathPolicy.normalizeRoot(endpoint.rootPath)
    }
}

/// Constructs an (unconnected) backend for a target + configuration. The DI
/// seam: production builds an ``FTPNetworkBackend``; tests build an in-memory
/// fake so the whole filesystem/adapter/byte-source path runs offline.
typealias FTPBackendMaker =
    @Sendable (FTPConnectionTarget, FTPMediaTransportConfiguration) -> any FTPBackend

/// FTP/FTPS `MediaTransportAdapter`. A stateless struct whose `connect`
/// produces a session owning its own control channel; per-playback cursors get
/// their own isolated backends. Mirrors `WebDAVMediaTransportAdapter` /
/// `SMBMediaTransportAdapter` exactly — the only new code is the protocol
/// backend it composes.
public struct FTPMediaTransportAdapter: MediaTransportAdapter, Sendable {
    public let transportIdentifier: String

    private let configurationProvider: FTPMediaTransportConfigurationProvider
    private let backendMaker: FTPBackendMaker

    public init(
        scheme: FTPScheme,
        configurationProvider: @escaping FTPMediaTransportConfigurationProvider
    ) {
        self.init(
            scheme: scheme,
            configurationProvider: configurationProvider,
            backendMaker: { target, configuration in
                FTPNetworkBackend(target: target, configuration: configuration)
            }
        )
    }

    init(
        scheme: FTPScheme,
        configurationProvider: @escaping FTPMediaTransportConfigurationProvider,
        backendMaker: @escaping FTPBackendMaker
    ) {
        self.transportIdentifier = scheme.rawValue
        self.configurationProvider = configurationProvider
        self.backendMaker = backendMaker
    }

    public func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        guard key.endpoint.transportIdentifier == transportIdentifier else {
            throw MediaTransportError.unsupportedCapability("transport")
        }

        // The provider owns the MediaTransportError contract (see the typealias
        // doc); its errors propagate unchanged so a permanent credential
        // failure stays terminal rather than being reclassified as transient.
        let configuration = try configurationProvider(key.accountID, key.credentialRevision)
        let target = try FTPConnectionTarget(endpoint: key.endpoint, security: configuration.security)

        let maker = backendMaker
        let backendFactory: FTPBackendFactory = {
            let backend = maker(target, configuration)
            do {
                try await backend.connect()
            } catch {
                await backend.shutdown()
                throw mapFTPError(error)
            }
            return backend
        }

        let primary = try await backendFactory()
        let fileSystem = FTPMediaTransportFileSystem(
            primary: primary,
            sourceBackendFactory: backendFactory,
            rootPath: target.rootPath,
            accountID: key.accountID,
            credentialRevision: key.credentialRevision
        )
        return FTPMediaTransportSession(key: key, fileSystem: fileSystem, primary: primary)
    }
}

final class FTPMediaTransportSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let primary: any FTPBackend

    init(
        key: MediaTransportSessionKey,
        fileSystem: any MediaTransportFileSystem,
        primary: any FTPBackend
    ) {
        self.key = key
        self.fileSystem = fileSystem
        self.primary = primary
    }

    func shutdown() async {
        // Closes the primary browse/scan control channel. Per-cursor playback
        // backends are owned + drained by their source leases independently.
        await primary.shutdown()
    }
}

final class FTPMediaTransportFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    static let maximumSmallFileSize = 16 * 1_024 * 1_024

    private let primary: any FTPBackend
    private let sourceBackendFactory: FTPBackendFactory
    private let rootPath: String
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        primary: any FTPBackend,
        sourceBackendFactory: @escaping FTPBackendFactory,
        rootPath: String,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.primary = primary
        self.sourceBackendFactory = sourceBackendFactory
        self.rootPath = rootPath
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func validate() async throws {
        do {
            _ = try await primary.list(path: rootPath)
        } catch {
            throw mapFTPError(error)
        }
    }

    func probe() async throws -> MediaTransportProbe {
        // Advertise honestly: seek (random access) requires the server to affirm
        // restart (`REST` in FEAT). A server without it can still list + read
        // whole small files, but is not seekable — advertised as `.bounded`, so
        // playback that needs seeking is truthfully gated (fail-closed policy,
        // mirroring WebDAV's per-file ETag enforcement). Per-file confirmation
        // happens at `openSource`.
        let supportsRestart = await primary.supportsRestart()
        return MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: supportsRestart ? .randomAccess : .bounded,
                maximumBoundedWholeFileReadBytes: Self.maximumSmallFileSize,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        let absolute = try FTPPathPolicy.absolutePath(root: rootPath, relative: relativePath)
        do {
            let entries = try await primary.list(path: absolute)
            return entries.compactMap { entry in
                guard let childPath = try? FTPPathPolicy.childRelativePath(
                    parent: relativePath,
                    name: entry.name
                ) else { return nil }
                return try? RemoteFileEntry(
                    relativePath: childPath,
                    kind: entry.kind,
                    size: entry.kind == .directory ? nil : entry.size,
                    modifiedAt: entry.modifiedAt
                )
            }
        } catch {
            throw mapFTPError(error)
        }
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        let absolute = try FTPPathPolicy.absolutePath(root: rootPath, relative: relativePath)
        do {
            let entry = try await primary.stat(path: absolute)
            return try RemoteFileEntry(
                relativePath: relativePath,
                kind: entry.kind,
                size: entry.kind == .directory ? nil : entry.size,
                modifiedAt: entry.modifiedAt
            )
        } catch {
            throw mapFTPError(error)
        }
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumSmallFileSize else {
            throw MediaTransportError.invalidInput(reason: "invalid small-file bound")
        }
        let absolute = try FTPPathPolicy.absolutePath(root: rootPath, relative: relativePath)
        do {
            return try await primary.readSmallFile(path: absolute, maximumBytes: maximumBytes)
        } catch {
            throw mapFTPError(error)
        }
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        guard locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else {
            throw MediaTransportError.invalidInput(reason: "locator session mismatch")
        }
        let absolute = try FTPPathPolicy.absolutePath(root: rootPath, relative: locator.relativePath)
        do {
            // Fail closed when the server can't do restart/ranged reads: the file
            // lists + stats fine but is not seekable, so it's not playable (the
            // FTP analogue of WebDAV rejecting a representation without a strong
            // ETag).
            guard await primary.supportsRestart() else {
                throw MediaTransportError.unsupportedRange(
                    reason: "FTP server does not support REST (not seekable)"
                )
            }
            // Re-validate against the current server state before committing to
            // playback, so a file changed since the scan fails fast.
            let current = try await primary.stat(path: absolute)
            guard current.kind == .file, let size = current.size else {
                throw MediaTransportError.sourceChanged(reason: "FTP file no longer a file")
            }
            try validateFTPRepresentation(
                size: size,
                modifiedAt: current.modifiedAt,
                against: locator.representation
            )
            let source = FTPCursorIsolatedByteSource(
                byteSize: locator.representation.size,
                path: absolute,
                expectedRepresentation: locator.representation,
                backendFactory: sourceBackendFactory
            )
            return MediaTransportSourceLease(source: source)
        } catch {
            throw mapFTPError(error)
        }
    }
}
