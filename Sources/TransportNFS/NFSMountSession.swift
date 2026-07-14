import Foundation

/// A live NFSv3 mount: the resolved root file handle plus a dedicated NFS
/// connection for metadata operations. An `actor` so calls on its shared
/// connection are serialized at the actor level, and the connection itself
/// serializes exchanges, matching the SMB backend's per-connection discipline.
public actor NFSMountSession {
    private let host: String
    private let exportPath: String
    private let mountPort: UInt16
    private let nfsPort: UInt16
    private let rootHandle: NFSFileHandle
    private let credential: RPCCredential
    private let timeout: Duration
    private let connectionFactory: any RPCConnectionFactory
    private let nfsClient: RPCClient
    private var isClosed = false

    /// Fixed READ chunk size. A server that prefers a smaller `rtmax` simply
    /// returns short reads (handled by the read loop), so a conservative fixed
    /// size avoids an FSINFO round trip whose failure could strand the mount.
    static let readSize = 512 * 1024

    init(
        host: String,
        exportPath: String,
        mountPort: UInt16,
        nfsPort: UInt16,
        rootHandle: NFSFileHandle,
        credential: RPCCredential,
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

    /// Lists a directory, guaranteeing every returned entry carries attributes.
    /// READDIRPLUS may omit both `name_attributes` and `name_handle`; in that
    /// case the entry is resolved with LOOKUP (+ GETATTR) rather than dropped,
    /// so a conforming server never yields an incomplete listing.
    public func list(relativePath: String) async throws -> [NFSDirectoryEntry] {
        let (dirHandle, attributes) = try await resolve(relativePath: relativePath)
        guard attributes.isDirectory else { throw NFSError.status(.notDirectory) }

        let raw = try await NFSProcedures.readDirectory(
            client: nfsClient,
            credential: credential,
            directory: dirHandle,
            maxCount: UInt32(Self.readSize)
        )

        var resolved: [NFSDirectoryEntry] = []
        resolved.reserveCapacity(raw.count)
        for entry in raw {
            if entry.attributes != nil {
                resolved.append(entry)
            } else if let filled = try? await fillEntry(entry, in: dirHandle) {
                resolved.append(filled)
            }
        }
        return resolved
    }

    /// Fills a READDIRPLUS entry that lacked attributes: GETATTR its handle if
    /// present, else LOOKUP it by name in the parent then GETATTR if needed.
    private func fillEntry(_ entry: NFSDirectoryEntry, in dirHandle: NFSFileHandle) async throws -> NFSDirectoryEntry {
        let handle: NFSFileHandle
        var attributes: NFSFileAttributes?
        if let entryHandle = entry.handle {
            handle = entryHandle
        } else {
            let result = try await NFSProcedures.lookup(
                client: nfsClient,
                credential: credential,
                directory: dirHandle,
                name: entry.name
            )
            handle = result.handle
            attributes = result.attributes
        }
        let filled: NFSFileAttributes
        if let attributes {
            filled = attributes
        } else {
            filled = try await NFSProcedures.getAttributes(
                client: nfsClient,
                credential: credential,
                handle: handle
            )
        }
        return NFSDirectoryEntry(
            name: entry.name,
            fileID: entry.fileID,
            handle: handle,
            attributes: filled
        )
    }

    /// Reads up to `length` bytes at `offset` on the metadata connection (used
    /// for small bounded reads). Chunks by the fixed read size.
    public func read(handle: NFSFileHandle, offset: Int64, length: Int) async throws -> Data {
        try await Self.readLoop(
            client: nfsClient,
            credential: credential,
            handle: handle,
            offset: offset,
            length: length,
            readSize: Self.readSize
        )
    }

    /// Opens a byte-source reader on its OWN dedicated NFS connection so
    /// playback reads never contend with scanner metadata (or with sibling
    /// cursors) on a shared channel. The reader revalidates the file's
    /// size/mtime on every read against `expectedModifiedAt`/`byteSize`.
    public func openReader(
        handle: NFSFileHandle,
        byteSize: Int64,
        expectedModifiedAt: Date
    ) async throws -> NFSFileReader {
        let connection = try await connectionFactory.connect(host: host, port: nfsPort, timeout: timeout)
        return NFSFileReader(
            connection: connection,
            handle: handle,
            credential: credential,
            byteSize: byteSize,
            expectedModifiedAt: expectedModifiedAt,
            readSize: Self.readSize
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
            credential: credential,
            arguments: encoder.data
        )
        await connection.close()
    }

    /// Shared bounded-read loop: issues successive `READ`s until `length` is
    /// satisfied or EOF, handling short reads.
    static func readLoop(
        client: RPCClient,
        credential: RPCCredential,
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
/// is stateless (handle + offset + count). Every `read` first revalidates the
/// file's size/mtime with a `GETATTR` (the NFS parallel of SMB's per-read
/// `fileStat` and WebDAV's per-read `If-Match`), so an in-place change or a
/// stale handle fails closed as `.representationChanged`/`.stale` instead of
/// silently mixing old and new bytes. An `actor`, but the underlying connection
/// also serializes exchanges, so concurrent reentrant calls can't interleave.
public actor NFSFileReader {
    private let connection: any RPCConnection
    private let client: RPCClient
    private let handle: NFSFileHandle
    private let credential: RPCCredential
    private let expectedModifiedAt: Date
    private let readSize: Int
    public let byteSize: Int64
    private var isClosed = false

    init(
        connection: any RPCConnection,
        handle: NFSFileHandle,
        credential: RPCCredential,
        byteSize: Int64,
        expectedModifiedAt: Date,
        readSize: Int
    ) {
        self.connection = connection
        self.client = RPCClient(connection: connection)
        self.handle = handle
        self.credential = credential
        self.byteSize = byteSize
        self.expectedModifiedAt = expectedModifiedAt
        self.readSize = readSize
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard !isClosed else { throw NFSError.cancelled }
        // Per-read revalidation: the file handle stays valid across an in-place
        // rewrite, so compare size + mtime every read to honor `.changeDetecting`.
        let current = try await NFSProcedures.getAttributes(
            client: client,
            credential: credential,
            handle: handle
        )
        guard current.isRegularFile,
              Int64(clamping: current.size) == byteSize,
              current.modifiedAt == expectedModifiedAt else {
            throw NFSError.representationChanged
        }
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
