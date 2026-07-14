import Foundation

/// Pure-Swift, read-only NFSv3 client.
///
/// Composes the XDR + ONC-RPC layers into the small set of operations Plozz's
/// scanner and player need: resolve the mount, browse directories, stat files,
/// read bounded ranges. Mirrors the layering discipline of the SMB/WebDAV
/// references — all protocol logic is offline-testable because the socket lives
/// behind ``RPCConnectionFactory``.
public struct NFSClient: Sendable {
    private let host: String
    private let credential: AuthUnixCredential
    private let timeout: Duration
    private let connectionFactory: any RPCConnectionFactory

    /// Public entry point. Uses the default `NWConnection`-backed transport and a
    /// plain (non-root) `AUTH_UNIX` identity — the right fit for the `insecure`
    /// exports a sandboxed tvOS client can reach.
    public init(host: String, timeout: Duration = .seconds(20)) {
        self.init(
            host: host,
            credential: .default,
            timeout: timeout,
            connectionFactory: NWRPCConnectionFactory()
        )
    }

    /// Full initializer — the DI seam tests use to inject a stubbed
    /// ``RPCConnectionFactory`` (and, if needed, a specific credential).
    init(
        host: String,
        credential: AuthUnixCredential,
        timeout: Duration,
        connectionFactory: any RPCConnectionFactory
    ) {
        self.host = host
        self.credential = credential
        self.timeout = timeout
        self.connectionFactory = connectionFactory
    }

    /// Mounts `exportPath` (e.g. `/volume1/media`) and returns a session bound to
    /// the resolved root file handle and a dedicated NFS connection.
    public func mount(exportPath: String) async throws -> NFSMountSession {
        // 1. portmap → mountd port (mountd is dynamic in NFSv3, so it MUST be
        //    resolved via portmap; there is no well-known fallback).
        guard let mountPort = try await resolvePort(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion
        ) else {
            throw NFSError.mountFailed(.notSupported)
        }

        // 2. MOUNT MNT → root file handle.
        let rootHandle = try await performMount(exportPath: exportPath, mountPort: mountPort)

        // 3. Resolve nfsd port (usually 2049) and open the NFS channel.
        let nfsPort = try await resolvePort(program: NFSProgram.nfs, version: NFSProgram.nfsVersion)
            ?? NFSWellKnownPort.nfs
        let nfsConnection = try await connectionFactory.connect(host: host, port: nfsPort, timeout: timeout)

        let session = NFSMountSession(
            host: host,
            exportPath: exportPath,
            mountPort: mountPort,
            nfsPort: nfsPort,
            rootHandle: rootHandle,
            credential: credential,
            timeout: timeout,
            connectionFactory: connectionFactory,
            nfsConnection: nfsConnection
        )
        // Best-effort rsize negotiation; failures fall back to the default.
        await session.negotiateReadSize()
        return session
    }

    // MARK: - portmap

    /// GETPORT for a program over TCP. Returns nil when unregistered (port 0).
    private func resolvePort(program: UInt32, version: UInt32) async throws -> UInt16? {
        let connection = try await connectionFactory.connect(
            host: host,
            port: NFSWellKnownPort.portmap,
            timeout: timeout
        )
        defer { Task { await connection.close() } }
        let client = RPCClient(connection: connection)

        var encoder = XDREncoder()
        encoder.encode(program)
        encoder.encode(version)
        encoder.encode(PortmapProcedure.protocolTCP)
        encoder.encode(UInt32(0))  // port (ignored for GETPORT)

        var decoder = try await client.call(
            program: NFSProgram.portmap,
            version: NFSProgram.portmapVersion,
            procedure: PortmapProcedure.getPort,
            credential: .none,
            arguments: encoder.data
        )
        let port = try decoder.decodeUInt32()
        guard port > 0, port <= UInt32(UInt16.max) else { return nil }
        return UInt16(port)
    }

    // MARK: - MOUNT

    private func performMount(exportPath: String, mountPort: UInt16) async throws -> NFSFileHandle {
        let connection = try await connectionFactory.connect(host: host, port: mountPort, timeout: timeout)
        defer { Task { await connection.close() } }
        let client = RPCClient(connection: connection)

        var encoder = XDREncoder()
        encoder.encodeString(exportPath)

        var decoder = try await client.call(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion,
            procedure: MountProcedure.mnt,
            credential: .unix(credential),
            arguments: encoder.data
        )
        let status = NFSStatus(rawValue: try decoder.decodeUInt32())
        guard status == .ok else {
            throw NFSError.mountFailed(status)
        }
        let handle = try decoder.decodeFileHandle()
        // auth_flavors list follows; we don't need it, but decode to validate.
        let flavorCount = try decoder.decodeUInt32()
        for _ in 0..<min(flavorCount, 16) { _ = try decoder.decodeUInt32() }
        return handle
    }
}
