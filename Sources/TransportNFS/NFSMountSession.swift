import Foundation

/// A live NFSv3 mount: the resolved root file handle plus a dedicated NFS
/// connection for metadata operations. An `actor` so calls on its shared
/// connection are serialized (single outstanding RPC), matching the SMB
/// backend's per-connection serialization.
public actor NFSMountSession {
    private let host: String
    private let exportPath: String
    private let mountPort: UInt16
    private let nfsPort: UInt16
    private let rootHandle: NFSFileHandle
    private let credential: AuthUnixCredential
    private let timeout: Duration
    private let connectionFactory: any RPCConnectionFactory
    private let nfsClient: RPCClient

    /// Preferred READ chunk size; negotiated from FSINFO, capped to 1 MiB.
    private var readSize: Int = 128 * 1024
    private var isClosed = false

    private static let maxReadSize = 1024 * 1024

    init(
        host: String,
        exportPath: String,
        mountPort: UInt16,
        nfsPort: UInt16,
        rootHandle: NFSFileHandle,
        credential: AuthUnixCredential,
        timeout: Duration,
        connectionFactory: any RPCConnectionFactory,
        nfsConnection: any RPCConnection
    ) {
        self.host = host
        self.exportPath = exportPath
        self.mountPort = mountPort
        self.nfsPort = nfsPort
        self.rootHandle = rootHandle
        self.credential = credential
        self.timeout = timeout
        self.connectionFactory = connectionFactory
        self.nfsClient = RPCClient(connection: nfsConnection)
    }

    func negotiateReadSize() async {
        if let rtpref = await NFSProcedures.readPreferredSize(
            client: nfsClient,
            credential: credential,
            handle: rootHandle
        ) {
            readSize = min(Int(rtpref), Self.maxReadSize)
        }
    }

    /// Attributes of the export root — used to prove the mount is browsable.
    public func rootAttributes() async throws -> NFSFileAttributes {
        try await NFSProcedures.getAttributes(
            client: nfsClient,
            credential: credential,
            handle: rootHandle
        )
    }

    /// Walks `relativePath` from the root, returning the final handle + attrs.
    public func resolve(relativePath: String) async throws -> (handle: NFSFileHandle, attributes: NFSFileAttributes) {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }

        var handle = rootHandle
        var attributes: NFSFileAttributes?
        for name in components {
            guard name != ".." else { throw NFSError.invalidArgument }
            let result = try await NFSProcedures.lookup(
                client: nfsClient,
                credential: credential,
                directory: handle,
                name: name
            )
            handle = result.handle
            attributes = result.attributes
        }

        if let attributes {
            return (handle, attributes)
        }
        let fetched = try await NFSProcedures.getAttributes(
            client: nfsClient,
            credential: credential,
            handle: handle
        )
        return (handle, fetched)
    }

    /// Lists a directory, guaranteeing every returned entry carries attributes
    /// (filling any the server omitted from `READDIRPLUS` via a follow-up
    /// `GETATTR`). Entries whose attributes can't be resolved are dropped rather
    /// than surfaced without a type/size.
    public func list(relativePath: String) async throws -> [NFSDirectoryEntry] {
        let (handle, attributes) = try await resolve(relativePath: relativePath)
        guard attributes.isDirectory else { throw NFSError.status(.notDirectory) }

        let raw = try await NFSProcedures.readDirectory(
            client: nfsClient,
            credential: credential,
            directory: handle,
            maxCount: UInt32(max(readSize, 64 * 1024))
        )

        var resolved: [NFSDirectoryEntry] = []
        resolved.reserveCapacity(raw.count)
        for entry in raw {
            if entry.attributes != nil {
                resolved.append(entry)
            } else if let entryHandle = entry.handle,
                      let filled = try? await NFSProcedures.getAttributes(
                          client: nfsClient,
                          credential: credential,
                          handle: entryHandle
                      ) {
                resolved.append(
                    NFSDirectoryEntry(
                        name: entry.name,
                        fileID: entry.fileID,
                        handle: entryHandle,
                        attributes: filled
                    )
                )
            }
        }
        return resolved
    }

    /// Reads up to `length` bytes at `offset` on the metadata connection (used
    /// for small bounded reads). Chunks by the negotiated read size.
    public func read(handle: NFSFileHandle, offset: Int64, length: Int) async throws -> Data {
        try await Self.readLoop(
            client: nfsClient,
            credential: credential,
            handle: handle,
            offset: offset,
            length: length,
            readSize: readSize
        )
    }

    /// Opens a byte-source reader on its OWN dedicated NFS connection so
    /// playback reads never contend with scanner metadata on the shared channel.
    public func openReader(handle: NFSFileHandle, byteSize: Int64) async throws -> NFSFileReader {
        let connection = try await connectionFactory.connect(host: host, port: nfsPort, timeout: timeout)
        return NFSFileReader(
            connection: connection,
            handle: handle,
            credential: credential,
            byteSize: byteSize,
            readSize: readSize
        )
    }

    public func shutdown() async {
        guard !isClosed else { return }
        isClosed = true
        await nfsClient.close()
        // Best-effort UMNT so the server's mount table doesn't leak this client.
        await bestEffortUnmount()
    }

    private func bestEffortUnmount() async {
        guard let connection = try? await connectionFactory.connect(
            host: host,
            port: mountPort,
            timeout: .seconds(5)
        ) else { return }
        let client = RPCClient(connection: connection)
        var encoder = XDREncoder()
        encoder.encodeString(exportPath)
        _ = try? await client.call(
            program: NFSProgram.mount,
            version: NFSProgram.mountVersion,
            procedure: MountProcedure.umnt,
            credential: .unix(credential),
            arguments: encoder.data
        )
        await connection.close()
    }

    /// Shared bounded-read loop: issues successive `READ`s until `length` is
    /// satisfied or EOF, handling short reads.
    static func readLoop(
        client: RPCClient,
        credential: AuthUnixCredential,
        handle: NFSFileHandle,
        offset: Int64,
        length: Int,
        readSize: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else { throw NFSError.invalidArgument }
        var result = Data()
        result.reserveCapacity(min(length, readSize))
        var current = UInt64(offset)
        var remaining = length
        while remaining > 0 {
            let count = UInt32(min(remaining, max(readSize, 1)))
            let chunk = try await NFSProcedures.read(
                client: client,
                credential: credential,
                handle: handle,
                offset: current,
                count: count
            )
            result.append(chunk.data)
            let advanced = chunk.data.count
            remaining -= advanced
            current += UInt64(advanced)
            if chunk.eof || advanced == 0 { break }
        }
        return result
    }
}

/// A random-access byte reader over one dedicated NFS connection. NFSv3 `READ`
/// is stateless (handle + offset + count), so this needs no server-side cursor
/// and no per-cursor isolation — a single reader serves sequential playback
/// reads. An `actor` serializes the single-outstanding RPC on its connection.
public actor NFSFileReader {
    private let connection: any RPCConnection
    private let client: RPCClient
    private let handle: NFSFileHandle
    private let credential: AuthUnixCredential
    private let readSize: Int
    public let byteSize: Int64
    private var isClosed = false

    init(
        connection: any RPCConnection,
        handle: NFSFileHandle,
        credential: AuthUnixCredential,
        byteSize: Int64,
        readSize: Int
    ) {
        self.connection = connection
        self.client = RPCClient(connection: connection)
        self.handle = handle
        self.credential = credential
        self.byteSize = byteSize
        self.readSize = readSize
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard !isClosed else { throw NFSError.cancelled }
        return try await NFSMountSession.readLoop(
            client: client,
            credential: credential,
            handle: handle,
            offset: offset,
            length: length,
            readSize: readSize
        )
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await connection.close()
    }
}
