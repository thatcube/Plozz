import Foundation

/// External Data Representation (RFC 4506) — the wire encoding shared by ONC-RPC,
/// portmap, MOUNT, and NFSv3. Everything is big-endian and 4-byte aligned.
///
/// Pure value types with no I/O so the whole encode/decode path is unit-testable
/// against captured/synthesized wire bytes, exactly the way the WebDAV and SMB
/// references keep their protocol logic offline-testable.
enum XDR {
    /// The fixed 4-byte alignment unit XDR pads every field up to.
    static let unit = 4

    /// Rounds `length` up to the next XDR 4-byte boundary.
    static func padded(_ length: Int) -> Int {
        let remainder = length % unit
        return remainder == 0 ? length : length + (unit - remainder)
    }
}

/// Append-only big-endian XDR encoder.
struct XDREncoder {
    var data = Data()

    init() {}

    mutating func encode(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func encode(_ value: Int32) {
        encode(UInt32(bitPattern: value))
    }

    mutating func encode(_ value: UInt64) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func encode(_ value: Int64) {
        encode(UInt64(bitPattern: value))
    }

    mutating func encode(_ value: Bool) {
        encode(value ? UInt32(1) : UInt32(0))
    }

    /// Variable-length opaque (`opaque<>`): 4-byte length, bytes, then padding.
    mutating func encodeOpaque(_ bytes: Data) {
        encode(UInt32(bytes.count))
        data.append(bytes)
        appendPadding(for: bytes.count)
    }

    /// Fixed-length opaque (`opaque[n]`): raw bytes plus padding, no length prefix.
    mutating func encodeFixedOpaque(_ bytes: Data) {
        data.append(bytes)
        appendPadding(for: bytes.count)
    }

    /// XDR string — encoded identically to a variable-length opaque.
    mutating func encodeString(_ string: String) {
        encodeOpaque(Data(string.utf8))
    }

    private mutating func appendPadding(for length: Int) {
        let pad = XDR.padded(length) - length
        if pad > 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: pad))
        }
    }
}

/// Sequential big-endian XDR decoder with bounds checking. Every read that would
/// run past the buffer throws ``NFSError.malformedResponse`` so a truncated or
/// hostile reply fails closed instead of reading uninitialized memory.
struct XDRDecoder {
    private let bytes: [UInt8]
    private(set) var cursor: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - cursor }
    var isAtEnd: Bool { cursor >= bytes.count }

    mutating func decodeUInt32() throws -> UInt32 {
        guard cursor + 4 <= bytes.count else { throw NFSError.malformedResponse }
        let value = (UInt32(bytes[cursor]) << 24)
            | (UInt32(bytes[cursor + 1]) << 16)
            | (UInt32(bytes[cursor + 2]) << 8)
            | UInt32(bytes[cursor + 3])
        cursor += 4
        return value
    }

    mutating func decodeInt32() throws -> Int32 {
        Int32(bitPattern: try decodeUInt32())
    }

    mutating func decodeUInt64() throws -> UInt64 {
        let high = try decodeUInt32()
        let low = try decodeUInt32()
        return (UInt64(high) << 32) | UInt64(low)
    }

    mutating func decodeInt64() throws -> Int64 {
        Int64(bitPattern: try decodeUInt64())
    }

    mutating func decodeBool() throws -> Bool {
        try decodeUInt32() != 0
    }

    /// Variable-length opaque: 4-byte length, bytes, then skip padding.
    mutating func decodeOpaque(maxLength: Int = 8 * 1024 * 1024) throws -> Data {
        let length = Int(try decodeUInt32())
        guard length <= maxLength else { throw NFSError.malformedResponse }
        return try decodeFixedOpaque(length)
    }

    /// Fixed-length opaque of exactly `length` bytes, then skip padding.
    mutating func decodeFixedOpaque(_ length: Int) throws -> Data {
        guard length >= 0, cursor + length <= bytes.count else {
            throw NFSError.malformedResponse
        }
        let slice = Data(bytes[cursor..<cursor + length])
        cursor += length
        try skipPadding(for: length)
        return slice
    }

    mutating func decodeString(maxLength: Int = 8 * 1024) throws -> String {
        let length = Int(try decodeUInt32())
        guard length <= maxLength else { throw NFSError.malformedResponse }
        let data = try decodeFixedOpaque(length)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NFSError.malformedResponse
        }
        return string
    }

    /// Skips `count` opaque bytes plus their padding without materializing them.
    mutating func skipOpaqueBytes(_ count: Int) throws {
        guard count >= 0, cursor + count <= bytes.count else {
            throw NFSError.malformedResponse
        }
        cursor += count
        try skipPadding(for: count)
    }

    private mutating func skipPadding(for length: Int) throws {
        let pad = XDR.padded(length) - length
        guard cursor + pad <= bytes.count else { throw NFSError.malformedResponse }
        cursor += pad
    }
}
