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
    private let nfsPortOverride: UInt16?
    private let timeout: Duration
    private let connectionFactory: any RPCConnectionFactory

    /// Public entry point. `nfsPort` overrides the nfsd port (from an explicit
    /// `nfs://host:port`); nil resolves it via portmap (falling back to 2049).
    /// Uses the default `NWConnection` transport and a plain `AUTH_UNIX` identity.
    public init(host: String, nfsPort: UInt16? = nil, timeout: Duration = .seconds(20)) {
        self.init(
            host: host,
            credential: .default,
            nfsPortOverride: nfsPort,
            timeout: timeout,
            connectionFactory: NWRPCConnectionFactory()
        )
    }

    /// Full initializer — the DI seam tests use to inject a stubbed
    /// ``RPCConnectionFactory`` (and, if needed, a specific credential).
    init(
        host: String,
        credential: AuthUnixCredential,
        nfsPortOverride: UInt16? = nil,
        timeout: Duration,
        connectionFactory: any RPCConnectionFactory
    ) {
        self.host = host
        self.credential = credential
        self.nfsPortOverride = nfsPortOverride
        self.timeout = timeout
        self.connectionFactory = connectionFactory
    }

    /// Mounts `exportPath` (e.g. `/volume1/media`) and returns a session bound to
    /// the resolved root file handle, a dedicated NFS connection, and the
    /// credential flavor the export advertised.
    public func mount(exportPath: String) async throws -> NFSMountSession {
        // 1. portmap → mountd port (mountd is dynamic in NFSv3, so it MUST be
        //    resolved via portmap; there is no well-known fallback).
        guard let mountPort = try await resolvePort(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion
        ) else {
            throw NFSError.mountFailed(.notSupported)
        }

        // 2. MOUNT MNT → root file handle + the credential the export accepts.
        let mounted = try await performMount(exportPath: exportPath, mountPort: mountPort)

        // 3. Resolve nfsd port (explicit override, else portmap, else 2049).
        let nfsPort: UInt16
        if let nfsPortOverride {
            nfsPort = nfsPortOverride
        } else {
            nfsPort = try await resolvePort(program: NFSProgram.nfs, version: NFSProgram.nfsVersion)
                ?? NFSWellKnownPort.nfs
        }
        let nfsConnection = try await connectionFactory.connect(host: host, port: nfsPort, timeout: timeout)

        return NFSMountSession(
            host: host,
            exportPath: exportPath,
            mountPort: mountPort,
            nfsPort: nfsPort,
            rootHandle: mounted.handle,
            credential: mounted.credential,
            timeout: timeout,
            connectionFactory: connectionFactory,
            nfsConnection: nfsConnection
        )
    }

    // MARK: - EXPORT (showmount -e)

    /// MOUNT EXPORT (procedure 5): the server's advertised export list, so
    /// onboarding can offer real export paths instead of making the user guess
    /// one. Returns the export dirpaths; the per-export access-group lists are
    /// decoded (to stay in sync with the wire) but discarded.
    ///
    /// Both list loops are bounded because the reply is server-controlled: a
    /// malformed or hostile mountd must not be able to make this allocate or spin
    /// without limit.
    public func listExports() async throws -> [String] {
        guard let mountPort = try await resolvePort(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion
        ) else {
            throw NFSError.mountFailed(.notSupported)
        }
        let connection = try await connectionFactory.connect(host: host, port: mountPort, timeout: timeout)
        defer { Task { await connection.close() } }
        let client = RPCClient(connection: connection)

        // EXPORT takes no arguments and, unlike MNT, returns the export list
        // directly (no leading mountstat3).
        var decoder = try await client.call(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion,
            procedure: MountProcedure.export,
            credential: .none,
            arguments: Data()
        )

        // exports  = *exportnode           (each link prefixed by a "value follows" bool)
        // exportnode { dirpath; groups; }
        // groups   = *name                 (same linked-list encoding)
        var exports: [String] = []
        var nodeCount = 0
        while try decoder.decodeBool() {
            let dirpath = try decoder.decodeString(maxLength: 4096)
            var groupCount = 0
            while try decoder.decodeBool() {
                _ = try decoder.decodeString(maxLength: 4096)
                groupCount += 1
                if groupCount > 4096 { break }
            }
            let trimmed = dirpath.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { exports.append(trimmed) }
            nodeCount += 1
            if nodeCount > 4096 { break }
        }
        return exports
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

    private func performMount(
        exportPath: String,
        mountPort: UInt16
    ) async throws -> (handle: NFSFileHandle, credential: RPCCredential) {
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

        // auth_flavors<>: pick the credential the export actually advertises so
        // an AUTH_NONE-only export doesn't fail every subsequent AUTH_UNIX call.
        let flavorCount = try decoder.decodeUInt32()
        var flavors: [UInt32] = []
        for _ in 0..<min(flavorCount, 16) {
            flavors.append(try decoder.decodeUInt32())
        }
        let selected: RPCCredential
        if flavors.isEmpty || flavors.contains(RPCConstants.authUnix) {
            selected = .unix(credential)          // the near-universal default
        } else if flavors.contains(RPCConstants.authNone) {
            selected = .none
        } else {
            selected = .unix(credential)          // best effort (e.g. GSS-only lists)
        }
        return (handle, selected)
    }
}
