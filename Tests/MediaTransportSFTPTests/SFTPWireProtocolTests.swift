import MediaTransportCore
import NIOCore
import XCTest

@testable import MediaTransportSFTP

/// Hermetic coverage of the pure SFTP v3 wire encode/decode layer — no network,
/// no event loop. This is the trickiest, most security-adjacent code (packet
/// framing, 64-bit offsets, attribute parsing), so it is exercised directly.
final class SFTPWireProtocolTests: XCTestCase {
    private let allocator = ByteBufferAllocator()

    // MARK: - Framing

    func testFrameWritesLengthTypeAndBody() {
        var body = allocator.buffer(capacity: 4)
        body.writeInteger(UInt32(0xDEAD_BEEF))
        var framed = SFTP.frame(type: .read, body: body, allocator: allocator)

        let length: UInt32 = framed.readInteger()!
        XCTAssertEqual(length, 5) // 1 type byte + 4 body bytes
        let type: UInt8 = framed.readInteger()!
        XCTAssertEqual(type, SFTP.PacketType.read.rawValue)
        let value: UInt32 = framed.readInteger()!
        XCTAssertEqual(value, 0xDEAD_BEEF)
        XCTAssertEqual(framed.readableBytes, 0)
    }

    func testNextPacketReturnsNilUntilComplete() throws {
        var body = allocator.buffer(capacity: 4)
        body.writeInteger(UInt32(7))
        let full = SFTP.frame(type: .status, body: body, allocator: allocator)

        // Feed all but the last byte: no complete packet yet.
        var partial = full
        let last = partial.readableBytes - 1
        var truncated = partial.readSlice(length: last)!
        XCTAssertNil(try SFTP.nextPacket(from: &truncated))

        // Feed everything: one packet, buffer fully consumed.
        var complete = full
        let packet = try XCTUnwrap(try SFTP.nextPacket(from: &complete))
        XCTAssertEqual(packet.type, SFTP.PacketType.status.rawValue)
        XCTAssertEqual(complete.readableBytes, 0)
    }

    func testNextPacketRejectsAbsurdLength() {
        var buffer = allocator.buffer(capacity: 8)
        buffer.writeInteger(UInt32(0x00FF_FFFF)) // > 1 MiB cap
        buffer.writeInteger(UInt8(SFTP.PacketType.status.rawValue))
        XCTAssertThrowsError(try SFTP.nextPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? MediaTransportError, .protocolViolation(reason: "invalid SFTP frame length"))
        }
    }

    // MARK: - Request encoders

    func testEncodeInitCarriesVersionAndNoID() throws {
        var packet = SFTP.encodeInit(allocator: allocator)
        _ = packet.readInteger(as: UInt32.self) // length
        let type: UInt8 = packet.readInteger()!
        XCTAssertEqual(type, SFTP.PacketType.initialize.rawValue)
        let version: UInt32 = packet.readInteger()!
        XCTAssertEqual(version, SFTP.protocolVersion)
        XCTAssertEqual(packet.readableBytes, 0)
    }

    func testEncodeReadCarriesOffsetAndLength() throws {
        let handle = ByteBuffer(bytes: [0xAB, 0xCD])
        var packet = SFTP.encodeRead(
            id: 42,
            handle: handle,
            offset: 0x1_0000_0000, // > UInt32.max, exercises 64-bit offset
            length: 4096,
            allocator: allocator
        )
        _ = packet.readInteger(as: UInt32.self) // length
        XCTAssertEqual(packet.readInteger(as: UInt8.self), SFTP.PacketType.read.rawValue)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 42)
        let handleBack = packet.readSSHStringSlice()!
        XCTAssertEqual(Array(handleBack.readableBytesView), [0xAB, 0xCD])
        XCTAssertEqual(packet.readInteger(as: UInt64.self), 0x1_0000_0000)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 4096)
    }

    func testEncodeOpenReadSetsReadFlag() throws {
        var packet = SFTP.encodeOpenRead(id: 1, path: "/media/movie.mkv", allocator: allocator)
        _ = packet.readInteger(as: UInt32.self)
        XCTAssertEqual(packet.readInteger(as: UInt8.self), SFTP.PacketType.open.rawValue)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 1)
        XCTAssertEqual(packet.readSSHString(), "/media/movie.mkv")
        XCTAssertEqual(packet.readInteger(as: UInt32.self), SFTP.openRead)
        XCTAssertEqual(packet.readInteger(as: UInt32.self), 0) // no attribute flags
    }

    // MARK: - Response decoders

    func testParseStatusBody() throws {
        var payload = allocator.buffer(capacity: 16)
        payload.writeInteger(SFTP.StatusCode.noSuchFile.rawValue)
        payload.writeSSHString("nope")
        let body = try SFTP.parseBody(type: SFTP.PacketType.status.rawValue, payload: &payload)
        guard case let .status(code, message) = body else {
            return XCTFail("expected status")
        }
        XCTAssertEqual(code, .noSuchFile)
        XCTAssertEqual(message, "nope")
    }

    func testParseDataBody() throws {
        var payload = allocator.buffer(capacity: 16)
        payload.writeSSHString(ByteBuffer(bytes: [1, 2, 3, 4]))
        let body = try SFTP.parseBody(type: SFTP.PacketType.data.rawValue, payload: &payload)
        guard case let .data(buffer) = body else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(Array(buffer.readableBytesView), [1, 2, 3, 4])
    }

    func testParseAttributesDerivesKindSizeAndModifiedAt() throws {
        // flags = SIZE | PERMISSIONS | ACMODTIME
        var payload = allocator.buffer(capacity: 32)
        payload.writeInteger(UInt32(0x0000_0001 | 0x0000_0004 | 0x0000_0008))
        payload.writeInteger(UInt64(123_456)) // size
        payload.writeInteger(UInt32(0o100_644)) // regular file
        payload.writeInteger(UInt32(1_000)) // atime
        payload.writeInteger(UInt32(2_000)) // mtime
        let body = try SFTP.parseBody(type: SFTP.PacketType.attrs.rawValue, payload: &payload)
        guard case let .attrs(attributes) = body else {
            return XCTFail("expected attrs")
        }
        XCTAssertEqual(attributes.size, 123_456)
        XCTAssertEqual(attributes.kind, .file)
        XCTAssertEqual(attributes.modificationTime, Date(timeIntervalSince1970: 2_000))
    }

    func testParseAttributesDirectoryKind() throws {
        var payload = allocator.buffer(capacity: 8)
        payload.writeInteger(UInt32(0x0000_0004)) // PERMISSIONS only
        payload.writeInteger(UInt32(0o040_755)) // directory
        let body = try SFTP.parseBody(type: SFTP.PacketType.attrs.rawValue, payload: &payload)
        guard case let .attrs(attributes) = body else {
            return XCTFail("expected attrs")
        }
        XCTAssertEqual(attributes.kind, .directory)
        XCTAssertNil(attributes.size)
    }

    func testParseNameEntries() throws {
        var payload = allocator.buffer(capacity: 64)
        payload.writeInteger(UInt32(2)) // count
        // entry 1: a directory
        payload.writeSSHString("Movies")
        payload.writeSSHString("drwxr-xr-x  ... Movies") // longname (ignored)
        payload.writeInteger(UInt32(0x0000_0004))
        payload.writeInteger(UInt32(0o040_755))
        // entry 2: a file with a size + mtime
        payload.writeSSHString("movie.mkv")
        payload.writeSSHString("-rw-r--r--  ... movie.mkv")
        payload.writeInteger(UInt32(0x0000_0001 | 0x0000_0004 | 0x0000_0008))
        payload.writeInteger(UInt64(42))
        payload.writeInteger(UInt32(0o100_644))
        payload.writeInteger(UInt32(10))
        payload.writeInteger(UInt32(20))

        let body = try SFTP.parseBody(type: SFTP.PacketType.name.rawValue, payload: &payload)
        guard case let .name(entries) = body else {
            return XCTFail("expected name")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].filename, "Movies")
        XCTAssertEqual(entries[0].attributes.kind, .directory)
        XCTAssertEqual(entries[1].filename, "movie.mkv")
        XCTAssertEqual(entries[1].attributes.kind, .file)
        XCTAssertEqual(entries[1].attributes.size, 42)
        XCTAssertEqual(entries[1].attributes.modificationTime, Date(timeIntervalSince1970: 20))
    }

    func testParseHandleBody() throws {
        var payload = allocator.buffer(capacity: 16)
        payload.writeSSHString(ByteBuffer(bytes: [0x10, 0x20, 0x30]))
        let body = try SFTP.parseBody(type: SFTP.PacketType.handle.rawValue, payload: &payload)
        guard case let .handle(handle) = body else {
            return XCTFail("expected handle")
        }
        XCTAssertEqual(Array(handle.readableBytesView), [0x10, 0x20, 0x30])
    }
}
