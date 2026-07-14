import Foundation

/// ONC-RPC program / procedure numbers and NFSv3 (RFC 1813) wire types used by
/// the read-only client: portmap (RFC 1833), MOUNT v3, and the handful of NFSv3
/// procedures needed to browse and read files.
enum NFSProgram {
    static let portmap: UInt32 = 100_000
    static let portmapVersion: UInt32 = 2
    static let mount: UInt32 = 100_005
    static let mountVersion: UInt32 = 3
    static let nfs: UInt32 = 100_003
    static let nfsVersion: UInt32 = 3
}

enum PortmapProcedure {
    static let getPort: UInt32 = 3
    static let protocolTCP: UInt32 = 6
}

enum MountProcedure {
    static let null: UInt32 = 0
    static let mnt: UInt32 = 1
    static let umnt: UInt32 = 3
    static let export: UInt32 = 5
}

enum NFSProcedure {
    static let null: UInt32 = 0
    static let getAttr: UInt32 = 1
    static let lookup: UInt32 = 3
    static let access: UInt32 = 4
    static let read: UInt32 = 6
    static let readDirPlus: UInt32 = 17
    static let fsInfo: UInt32 = 19
}

/// The default port for `nfsd`. Modern servers keep NFS on 2049 even when mountd
/// is dynamic; the client still resolves mountd (and optionally nfsd) via
/// portmap.
enum NFSWellKnownPort {
    static let nfs: UInt16 = 2049
    static let portmap: UInt16 = 111
}

/// NFSv3 file type (`ftype3`).
public enum NFSFileType: Sendable, Equatable {
    case regular
    case directory
    case symlink
    case other

    init(rawValue: UInt32) {
        switch rawValue {
        case 1: self = .regular
        case 2: self = .directory
        case 5: self = .symlink
        default: self = .other
        }
    }
}

/// An NFSv3 opaque file handle (`nfs_fh3`, max 64 bytes).
public struct NFSFileHandle: Sendable, Equatable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

/// The subset of `fattr3` the media client needs: type, size, identity, mtime.
public struct NFSFileAttributes: Sendable, Equatable {
    public let type: NFSFileType
    public let size: UInt64
    public let fileID: UInt64
    public let fsID: UInt64
    public let modifiedAt: Date

    public var isDirectory: Bool { type == .directory }
    public var isRegularFile: Bool { type == .regular }
}

/// One entry from a `READDIRPLUS` reply.
public struct NFSDirectoryEntry: Sendable, Equatable {
    public let name: String
    public let fileID: UInt64
    public let handle: NFSFileHandle?
    public let attributes: NFSFileAttributes?
}

/// The result of a bounded `READ`.
struct NFSReadResult: Sendable, Equatable {
    let data: Data
    let eof: Bool
}

// MARK: - fattr3 / post_op_attr decoding

extension XDRDecoder {
    /// Decodes a full `fattr3` structure.
    mutating func decodeFileAttributes() throws -> NFSFileAttributes {
        let type = NFSFileType(rawValue: try decodeUInt32())
        _ = try decodeUInt32()               // mode
        _ = try decodeUInt32()               // nlink
        _ = try decodeUInt32()               // uid
        _ = try decodeUInt32()               // gid
        let size = try decodeUInt64()        // size
        _ = try decodeUInt64()               // used
        _ = try decodeUInt32()               // rdev.specdata1
        _ = try decodeUInt32()               // rdev.specdata2
        let fsID = try decodeUInt64()        // fsid
        let fileID = try decodeUInt64()      // fileid
        _ = try decodeTime()                 // atime
        let mtime = try decodeTime()         // mtime
        _ = try decodeTime()                 // ctime
        return NFSFileAttributes(
            type: type,
            size: size,
            fileID: fileID,
            fsID: fsID,
            modifiedAt: mtime
        )
    }

    /// `post_op_attr` — an optional `fattr3` guarded by a boolean.
    mutating func decodePostOpAttributes() throws -> NFSFileAttributes? {
        guard try decodeBool() else { return nil }
        return try decodeFileAttributes()
    }

    /// `post_op_fh3` — an optional `nfs_fh3` guarded by a boolean.
    mutating func decodePostOpHandle() throws -> NFSFileHandle? {
        guard try decodeBool() else { return nil }
        return NFSFileHandle(bytes: try decodeOpaque(maxLength: 64))
    }

    /// `nfs_fh3` — a length-prefixed opaque handle, max 64 bytes.
    mutating func decodeFileHandle() throws -> NFSFileHandle {
        NFSFileHandle(bytes: try decodeOpaque(maxLength: 64))
    }

    /// `nfstime3` — seconds + nanoseconds since the Unix epoch.
    private mutating func decodeTime() throws -> Date {
        let seconds = try decodeUInt32()
        let nanoseconds = try decodeUInt32()
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}
