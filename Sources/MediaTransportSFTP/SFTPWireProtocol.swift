import Foundation
import MediaTransportCore
import NIOCore

/// The subset of the SFTP protocol (draft-ietf-secsh-filexfer-02, "version 3" —
/// the dialect OpenSSH speaks) that a read-only media browser needs. Only the
/// request/response packets Plozz issues are modeled: INIT/VERSION, REALPATH,
/// OPENDIR/READDIR, OPEN(read)/READ/CLOSE, and (L/F)STAT. Write, mkdir, rename,
/// symlink, and the rest are deliberately absent — the transport never mutates
/// the remote share.
///
/// Everything here is pure ByteBuffer framing with no I/O, so the packet
/// encoders/decoders are unit-testable without a live SSH connection.
enum SFTP {
    /// Protocol version Plozz negotiates. Version 3 is universally supported and
    /// carries the 32-bit `atime`/`mtime` attribute shape this code parses.
    static let protocolVersion: UInt32 = 3

    /// A conservative per-`READ` chunk. Effectively every SFTP server accepts a
    /// 32 KiB read; larger reads risk `SSH_FX_BAD_MESSAGE` on stricter servers.
    /// Higher-level reads loop over this to satisfy an arbitrary request length.
    static let maxReadChunk = 32_768

    /// Packet type identifiers (`SSH_FXP_*`).
    enum PacketType: UInt8 {
        case initialize = 1   // SSH_FXP_INIT
        case version = 2      // SSH_FXP_VERSION
        case open = 3         // SSH_FXP_OPEN
        case close = 4        // SSH_FXP_CLOSE
        case read = 5         // SSH_FXP_READ
        case lstat = 7        // SSH_FXP_LSTAT
        case fstat = 8        // SSH_FXP_FSTAT
        case opendir = 11     // SSH_FXP_OPENDIR
        case readdir = 12     // SSH_FXP_READDIR
        case realpath = 16    // SSH_FXP_REALPATH
        case stat = 17        // SSH_FXP_STAT
        case status = 101     // SSH_FXP_STATUS
        case handle = 102     // SSH_FXP_HANDLE
        case data = 103       // SSH_FXP_DATA
        case name = 104       // SSH_FXP_NAME
        case attrs = 105      // SSH_FXP_ATTRS
    }

    /// `SSH_FX_*` status codes returned in an `SSH_FXP_STATUS` packet.
    enum StatusCode: UInt32, Sendable {
        case ok = 0
        case eof = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case operationUnsupported = 8
        case unknown = 0xFFFF_FFFF
    }

    /// `SSH_FXF_*` open flags. Read-only, so only `READ` is ever set.
    static let openRead: UInt32 = 0x0000_0001

    // MARK: - File attributes (`ATTRS`)

    /// `SSH_FILEXFER_ATTR_*` presence flags.
    private static let attrSize: UInt32 = 0x0000_0001
    private static let attrUIDGID: UInt32 = 0x0000_0002
    private static let attrPermissions: UInt32 = 0x0000_0004
    private static let attrACModTime: UInt32 = 0x0000_0008
    private static let attrExtended: UInt32 = 0x8000_0000

    /// POSIX `S_IFMT` mask + directory/regular/symlink type bits, used to derive
    /// the entry kind from the `permissions` attribute.
    private static let sIFMT: UInt32 = 0o170000
    private static let sIFDIR: UInt32 = 0o040000
    private static let sIFREG: UInt32 = 0o100000
    private static let sIFLNK: UInt32 = 0o120000

    struct FileAttributes: Equatable, Sendable {
        var size: Int64?
        var permissions: UInt32?
        var modificationTime: Date?

        var kind: RemoteFileEntryKind? {
            guard let permissions else { return nil }
            switch permissions & SFTP.sIFMT {
            case SFTP.sIFDIR: return .directory
            case SFTP.sIFLNK: return .symlink
            case SFTP.sIFREG: return .file
            default: return nil
            }
        }
    }

    /// One entry of an `SSH_FXP_NAME` response.
    struct NameEntry: Equatable, Sendable {
        var filename: String
        var attributes: FileAttributes
    }

    /// A decoded response body (everything after the packet's leading
    /// request-id, which the transport layer strips to route the reply).
    enum ResponseBody: Sendable {
        case status(StatusCode, message: String)
        case handle(ByteBuffer)
        case data(ByteBuffer)
        case name([NameEntry])
        case attrs(FileAttributes)
    }
}

// MARK: - ByteBuffer SSH-string helpers

extension ByteBuffer {
    /// Writes an SSH `string`: a `uint32` length prefix followed by the raw
    /// bytes (RFC 4251 §5).
    mutating func writeSSHString(_ bytes: [UInt8]) {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func writeSSHString(_ string: String) {
        writeSSHString(Array(string.utf8))
    }

    mutating func writeSSHString(_ buffer: ByteBuffer) {
        writeInteger(UInt32(buffer.readableBytes))
        var copy = buffer
        writeBuffer(&copy)
    }

    /// Reads an SSH `string` as a raw slice, advancing the reader index.
    mutating func readSSHStringSlice() -> ByteBuffer? {
        guard let length: UInt32 = readInteger(),
              let slice = readSlice(length: Int(length)) else {
            return nil
        }
        return slice
    }

    mutating func readSSHString() -> String? {
        guard var slice = readSSHStringSlice() else { return nil }
        return slice.readString(length: slice.readableBytes)
    }
}

// MARK: - Request encoding

extension SFTP {
    /// Frames a request body into a complete on-the-wire SFTP packet:
    /// `uint32 length | byte type | body`. The `length` counts `type` + `body`.
    static func frame(type: PacketType, body: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var packet = allocator.buffer(capacity: body.readableBytes + 5)
        packet.writeInteger(UInt32(body.readableBytes + 1))
        packet.writeInteger(type.rawValue)
        var copy = body
        packet.writeBuffer(&copy)
        return packet
    }

    /// `SSH_FXP_INIT` carries only the protocol version and no request id.
    static func encodeInit(allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 4)
        body.writeInteger(protocolVersion)
        return frame(type: .initialize, body: body, allocator: allocator)
    }

    static func encodeRealPath(id: UInt32, path: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: path.utf8.count + 8)
        body.writeInteger(id)
        body.writeSSHString(path)
        return frame(type: .realpath, body: body, allocator: allocator)
    }

    static func encodeOpenDir(id: UInt32, path: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: path.utf8.count + 8)
        body.writeInteger(id)
        body.writeSSHString(path)
        return frame(type: .opendir, body: body, allocator: allocator)
    }

    static func encodeReadDir(id: UInt32, handle: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: handle.readableBytes + 8)
        body.writeInteger(id)
        body.writeSSHString(handle)
        return frame(type: .readdir, body: body, allocator: allocator)
    }

    static func encodeStat(id: UInt32, path: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: path.utf8.count + 8)
        body.writeInteger(id)
        body.writeSSHString(path)
        return frame(type: .stat, body: body, allocator: allocator)
    }

    static func encodeLStat(id: UInt32, path: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: path.utf8.count + 8)
        body.writeInteger(id)
        body.writeSSHString(path)
        return frame(type: .lstat, body: body, allocator: allocator)
    }

    static func encodeFStat(id: UInt32, handle: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: handle.readableBytes + 8)
        body.writeInteger(id)
        body.writeSSHString(handle)
        return frame(type: .fstat, body: body, allocator: allocator)
    }

    static func encodeOpenRead(id: UInt32, path: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: path.utf8.count + 16)
        body.writeInteger(id)
        body.writeSSHString(path)
        body.writeInteger(openRead)
        body.writeInteger(UInt32(0)) // attribute flags: none
        return frame(type: .open, body: body, allocator: allocator)
    }

    static func encodeRead(
        id: UInt32,
        handle: ByteBuffer,
        offset: UInt64,
        length: UInt32,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var body = allocator.buffer(capacity: handle.readableBytes + 20)
        body.writeInteger(id)
        body.writeSSHString(handle)
        body.writeInteger(offset)
        body.writeInteger(length)
        return frame(type: .read, body: body, allocator: allocator)
    }

    static func encodeClose(id: UInt32, handle: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: handle.readableBytes + 8)
        body.writeInteger(id)
        body.writeSSHString(handle)
        return frame(type: .close, body: body, allocator: allocator)
    }
}

// MARK: - Response decoding

extension SFTP {
    /// A framed packet split into its `type` and the payload following the
    /// leading `uint32 length | byte type`.
    struct RawPacket {
        var type: UInt8
        var payload: ByteBuffer
    }

    /// Attempts to peel one complete packet off the front of `buffer`. Returns
    /// `nil` (leaving `buffer` untouched) when fewer than a full packet's bytes
    /// have arrived, so the caller can wait for more data.
    static func nextPacket(from buffer: inout ByteBuffer) throws -> RawPacket? {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else {
            return nil
        }
        guard length >= 1, length <= 0x0010_0000 else {
            // A zero-length or absurdly large frame means the stream is
            // desynchronized; fail closed rather than trying to resync.
            throw MediaTransportError.protocolViolation(reason: "invalid SFTP frame length")
        }
        let total = Int(length) + 4
        guard buffer.readableBytes >= total else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let type: UInt8 = buffer.readInteger(),
              let payload = buffer.readSlice(length: Int(length) - 1) else {
            throw MediaTransportError.protocolViolation(reason: "truncated SFTP packet")
        }
        return RawPacket(type: type, payload: payload)
    }

    /// Parses the negotiated version out of an `SSH_FXP_VERSION` packet.
    static func parseVersion(_ payload: inout ByteBuffer) throws -> UInt32 {
        guard let version: UInt32 = payload.readInteger() else {
            throw MediaTransportError.protocolViolation(reason: "malformed SFTP VERSION")
        }
        return version
    }

    /// Parses a response body (request-id already consumed by the caller).
    static func parseBody(type: UInt8, payload: inout ByteBuffer) throws -> ResponseBody {
        guard let packetType = PacketType(rawValue: type) else {
            throw MediaTransportError.protocolViolation(reason: "unknown SFTP packet type")
        }
        switch packetType {
        case .status:
            guard let raw: UInt32 = payload.readInteger() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP STATUS")
            }
            let message = payload.readSSHString() ?? ""
            return .status(StatusCode(rawValue: raw) ?? .unknown, message: message)
        case .handle:
            guard let handle = payload.readSSHStringSlice() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP HANDLE")
            }
            return .handle(handle)
        case .data:
            guard let data = payload.readSSHStringSlice() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP DATA")
            }
            return .data(data)
        case .name:
            return .name(try parseNames(&payload))
        case .attrs:
            return .attrs(try parseAttributes(&payload))
        default:
            throw MediaTransportError.protocolViolation(reason: "unexpected SFTP response packet")
        }
    }

    private static func parseNames(_ payload: inout ByteBuffer) throws -> [NameEntry] {
        guard let count: UInt32 = payload.readInteger() else {
            throw MediaTransportError.protocolViolation(reason: "malformed SFTP NAME count")
        }
        guard count <= 65_535 else {
            throw MediaTransportError.protocolViolation(reason: "SFTP NAME count too large")
        }
        var entries: [NameEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let filename = payload.readSSHString(),
                  payload.readSSHString() != nil // longname (ignored)
            else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP NAME entry")
            }
            let attributes = try parseAttributes(&payload)
            entries.append(NameEntry(filename: filename, attributes: attributes))
        }
        return entries
    }

    private static func parseAttributes(_ payload: inout ByteBuffer) throws -> FileAttributes {
        guard let flags: UInt32 = payload.readInteger() else {
            throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS flags")
        }
        var attributes = FileAttributes(size: nil, permissions: nil, modificationTime: nil)

        if flags & attrSize != 0 {
            guard let size: UInt64 = payload.readInteger() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS size")
            }
            attributes.size = Int64(clamping: size)
        }
        if flags & attrUIDGID != 0 {
            guard payload.readInteger(as: UInt32.self) != nil,
                  payload.readInteger(as: UInt32.self) != nil else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS uid/gid")
            }
        }
        if flags & attrPermissions != 0 {
            guard let permissions: UInt32 = payload.readInteger() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS permissions")
            }
            attributes.permissions = permissions
        }
        if flags & attrACModTime != 0 {
            guard payload.readInteger(as: UInt32.self) != nil,
                  let mtime: UInt32 = payload.readInteger() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS times")
            }
            attributes.modificationTime = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        if flags & attrExtended != 0 {
            guard let count: UInt32 = payload.readInteger() else {
                throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS extended count")
            }
            guard count <= 4_096 else {
                throw MediaTransportError.protocolViolation(reason: "SFTP ATTRS extended count too large")
            }
            for _ in 0..<count {
                guard payload.readSSHString() != nil, payload.readSSHString() != nil else {
                    throw MediaTransportError.protocolViolation(reason: "malformed SFTP ATTRS extended pair")
                }
            }
        }
        return attributes
    }
}
