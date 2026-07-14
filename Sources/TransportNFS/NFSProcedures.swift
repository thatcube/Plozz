import Foundation

/// The NFSv3 procedures the read-only client issues, as free async functions
/// over an ``RPCClient``. Keeping them stateless lets both the metadata session
/// and each byte-source reader (which own separate connections) share one
/// implementation, and lets tests exercise each procedure against a stubbed
/// connection.
enum NFSProcedures {
    /// Caps on a directory listing so a hostile/looping server can't exhaust
    /// memory or spin forever.
    static let maxDirectoryEntries = 200_000
    static let maxReadDirIterations = 4_096

    static func getAttributes(
        client: RPCClient,
        credential: AuthUnixCredential,
        handle: NFSFileHandle
    ) async throws -> NFSFileAttributes {
        var encoder = XDREncoder()
        encoder.encodeOpaque(handle.bytes)
        var decoder = try await client.call(
            program: NFSProgram.nfs,
            version: NFSProgram.nfsVersion,
            procedure: NFSProcedure.getAttr,
            credential: .unix(credential),
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        return try decoder.decodeFileAttributes()
    }

    static func lookup(
        client: RPCClient,
        credential: AuthUnixCredential,
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
            credential: .unix(credential),
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        let handle = try decoder.decodeFileHandle()
        let attributes = try decoder.decodePostOpAttributes()
        return (handle, attributes)
    }

    static func read(
        client: RPCClient,
        credential: AuthUnixCredential,
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
            credential: .unix(credential),
            arguments: encoder.data
        )
        try throwIfNotOK(&decoder)
        _ = try decoder.decodePostOpAttributes()  // file_attributes
        _ = try decoder.decodeUInt32()             // count (redundant with data length)
        let eof = try decoder.decodeBool()
        let data = try decoder.decodeOpaque(maxLength: 64 * 1024 * 1024)
        return NFSReadResult(data: data, eof: eof)
    }

    /// Reads a whole directory, following `cookie`/`cookieverf` pagination until
    /// EOF. Skips `.`/`..`.
    static func readDirectory(
        client: RPCClient,
        credential: AuthUnixCredential,
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
                credential: .unix(credential),
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
            // No progress guard: a server that returns neither entries nor EOF
            // would otherwise loop forever.
            guard sawEntry, lastCookie != cookie else { break }
            cookie = lastCookie
        }
        return entries
    }

    /// FSINFO → preferred read size (`rtpref`), used to size READ chunks. Best
    /// effort; returns nil on any failure so the caller keeps its default.
    static func readPreferredSize(
        client: RPCClient,
        credential: AuthUnixCredential,
        handle: NFSFileHandle
    ) async -> UInt32? {
        var encoder = XDREncoder()
        encoder.encodeOpaque(handle.bytes)
        do {
            var decoder = try await client.call(
                program: NFSProgram.nfs,
                version: NFSProgram.nfsVersion,
                procedure: NFSProcedure.fsInfo,
                credential: .unix(credential),
                arguments: encoder.data
            )
            let status = NFSStatus(rawValue: try decoder.decodeUInt32())
            guard status == .ok else { return nil }
            _ = try decoder.decodePostOpAttributes()  // obj_attributes
            _ = try decoder.decodeUInt32()             // rtmax
            let rtpref = try decoder.decodeUInt32()    // rtpref
            return rtpref > 0 ? rtpref : nil
        } catch {
            return nil
        }
    }

    /// Reads the leading `nfsstat3` of a result and throws when it isn't OK.
    private static func throwIfNotOK(_ decoder: inout XDRDecoder) throws {
        let status = NFSStatus(rawValue: try decoder.decodeUInt32())
        guard status == .ok else { throw NFSError.status(status) }
    }
}
