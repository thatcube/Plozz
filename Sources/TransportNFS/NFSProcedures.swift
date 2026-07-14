import Foundation

/// The NFSv3 procedures the read-only client issues, as free async functions
/// over an ``RPCClient``. Keeping them stateless lets both the metadata session
/// and each byte-source reader (which own separate connections) share one
/// implementation, and lets tests exercise each procedure against a stubbed
/// connection. The `credential` is an already-selected ``RPCCredential`` (the
/// mount negotiates AUTH_UNIX vs AUTH_NONE from the export's advertised flavors).
enum NFSProcedures {
    /// Caps on a directory listing so a hostile/looping server can't exhaust
    /// memory or spin forever.
    static let maxDirectoryEntries = 200_000
    static let maxReadDirIterations = 4_096

    static func getAttributes(
        client: RPCClient,
        credential: RPCCredential,
        handle: NFSFileHandle
    ) async throws -> NFSFileAttributes {
        var encoder = XDREncoder()
        encoder.encodeOpaque(handle.bytes)
        var decoder = try await client.call(
            program: NFSProgram.nfs,
            version: NFSProgram.nfsVersion,
            procedure: NFSProcedure.getAttr,
            credential: credential,
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        return try decoder.decodeFileAttributes()
    }

    static func lookup(
        client: RPCClient,
        credential: RPCCredential,
        directory: NFSFileHandle,
        name: String
    ) async throws -> (handle: NFSFileHandle, attributes: NFSFileAttributes?) {
        var encoder = XDREncoder()
        encoder.encodeOpaque(directory.bytes)
        encoder.encodeString(name)
        var decoder = try await client.call(
            program: NFSProgram.nfs,
            version: NFSProgram.nfsVersion,
            procedure: NFSProcedure.lookup,
            credential: credential,
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        let handle = try decoder.decodeFileHandle()
        let attributes = try decoder.decodePostOpAttributes()
        return (handle, attributes)
    }

    static func read(
        client: RPCClient,
        credential: RPCCredential,
        handle: NFSFileHandle,
        offset: UInt64,
        count: UInt32
    ) async throws -> NFSReadResult {
        var encoder = XDREncoder()
        encoder.encodeOpaque(handle.bytes)
        encoder.encode(offset)
        encoder.encode(count)
        var decoder = try await client.call(
            program: NFSProgram.nfs,
            version: NFSProgram.nfsVersion,
            procedure: NFSProcedure.read,
            credential: credential,
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        _ = try decoder.decodePostOpAttributes()   // file_attributes
        let declaredCount = try decoder.decodeUInt32()
        let eof = try decoder.decodeBool()
        // Bound the returned data to what we requested — a server must not hand
        // back more than `count` bytes, and the declared count must match the
        // opaque length. Caps allocation and enforces the byte-source range
        // contract.
        let data = try decoder.decodeOpaque(maxLength: Int(count))
        guard data.count == Int(declaredCount), data.count <= Int(count) else {
            throw NFSError.malformedResponse
        }
        return NFSReadResult(data: data, eof: eof)
    }

    /// Reads a whole directory, following `cookie`/`cookieverf` pagination until
    /// EOF. Skips `.`/`..`.
    static func readDirectory(
        client: RPCClient,
        credential: RPCCredential,
        directory: NFSFileHandle,
        maxCount: UInt32
    ) async throws -> [NFSDirectoryEntry] {
        var entries: [NFSDirectoryEntry] = []
        var cookie: UInt64 = 0
        var cookieVerf = Data(count: 8)
        let dirCount = min(maxCount / 2, 32_768)

        for _ in 0..<maxReadDirIterations {
            var encoder = XDREncoder()
            encoder.encodeOpaque(directory.bytes)
            encoder.encode(cookie)
            encoder.encodeFixedOpaque(cookieVerf)
            encoder.encode(dirCount)
            encoder.encode(maxCount)

            var decoder = try await client.call(
                program: NFSProgram.nfs,
                version: NFSProgram.nfsVersion,
                procedure: NFSProcedure.readDirPlus,
                credential: credential,
                arguments: encoder.data
            )
            try throwIfNotOK(&decoder)
            _ = try decoder.decodePostOpAttributes()          // dir_attributes
            cookieVerf = try decoder.decodeFixedOpaque(8)      // cookieverf3

            var lastCookie = cookie
            var sawEntry = false
            var follows = try decoder.decodeBool()
            while follows {
                let fileID = try decoder.decodeUInt64()
                let name = try decoder.decodeString(maxLength: 4 * 1024)
                let entryCookie = try decoder.decodeUInt64()
                let attributes = try decoder.decodePostOpAttributes()
                let handle = try decoder.decodePostOpHandle()
                if name != ".", name != ".." {
                    entries.append(
                        NFSDirectoryEntry(
                            name: name,
                            fileID: fileID,
                            handle: handle,
                            attributes: attributes
                        )
                    )
                    guard entries.count <= maxDirectoryEntries else {
                        throw NFSError.malformedResponse
                    }
                }
                lastCookie = entryCookie
                sawEntry = true
                follows = try decoder.decodeBool()
            }
            let eof = try decoder.decodeBool()
            if eof { break }
            // No-progress guard: a server that returns neither entries nor EOF
            // would otherwise loop forever.
            guard sawEntry, lastCookie != cookie else { break }
            cookie = lastCookie
        }
        return entries
    }

    /// Reads the leading `nfsstat3` of a result and throws when it isn't OK.
    private static func throwIfNotOK(_ decoder: inout XDRDecoder) throws {
        let status = NFSStatus(rawValue: try decoder.decodeUInt32())
        guard status == .ok else { throw NFSError.status(status) }
    }
}
