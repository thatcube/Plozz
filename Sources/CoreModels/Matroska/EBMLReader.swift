import Foundation

/// A minimal, allocation-light EBML (Matroska container) primitive reader.
///
/// This is **pure value logic** with no platform dependency so the cue/segment
/// math that drives the local-remux HLS playlist can be unit-tested in isolation
/// on any platform. It reads only what the cue-driven remuxer needs — element
/// IDs, variable-length integers (vints), and the unsigned/float/string/binary
/// payloads of the handful of Matroska elements involved in seeking — and it is
/// deliberately tolerant of buffers that contain only *part* of the file (a
/// ranged read of the header or the Cues block), reporting how far it got rather
/// than trapping.
///
/// EBML encoding recap:
///   * An **element** is `[ID][data-size][data]`.
///   * Both the ID and the data-size are vints. The first byte's leading-zero
///     count selects the total octet length (`leadingZeros + 1`, 1...8).
///   * An **ID** keeps its length-marker bit, so `0x1A` → a 4-octet ID whose
///     value is `0x1A45DFA3`.
///   * A **data size** strips the marker bit, so `0x84` → size `4`. A size whose
///     data bits are all `1` means "unknown size" (streamed) and is reported as
///     `nil`.
public struct EBMLReader {
    /// The backing bytes. May be the whole file or a contiguous window of it.
    public let data: [UInt8]
    /// The absolute file offset of `data[0]`, so positions inside the buffer can
    /// be reported in whole-file coordinates (Matroska `SeekHead`/`Cues`
    /// positions are expressed relative to the Segment, which is itself an
    /// absolute file offset).
    public let baseOffset: Int
    /// The current read position as an index into `data` (0-based).
    public private(set) var cursor: Int

    public init(data: [UInt8], baseOffset: Int = 0, cursor: Int = 0) {
        self.data = data
        self.baseOffset = baseOffset
        self.cursor = cursor
    }

    public init(data: Data, baseOffset: Int = 0, cursor: Int = 0) {
        self.init(data: [UInt8](data), baseOffset: baseOffset, cursor: cursor)
    }

    /// Bytes remaining from the cursor to the end of the buffer.
    public var remaining: Int { data.count - cursor }

    /// The absolute file offset of the current cursor.
    public var absolutePosition: Int { baseOffset + cursor }

    public mutating func seek(toLocal index: Int) {
        cursor = max(0, min(index, data.count))
    }

    /// Move the cursor to an absolute file offset, clamped into the buffer.
    public mutating func seek(toAbsolute offset: Int) {
        seek(toLocal: offset - baseOffset)
    }

    // MARK: - Variable-length integers

    /// Decodes the vint at the cursor *without* advancing it.
    /// - Parameter keepMarker: `true` for element IDs (the length-marker bit is
    ///   part of the value); `false` for data sizes/most payloads.
    /// - Returns: the decoded value (or `nil` for an all-ones "unknown size"),
    ///   plus the octet length, or `nil` if the buffer is truncated.
    public func peekVInt(keepMarker: Bool) -> (value: UInt64?, length: Int)? {
        guard cursor < data.count else { return nil }
        let first = data[cursor]
        guard first != 0 else { return nil } // 9+ octet vints are unsupported here
        let length = leadingZeroOctetLength(first)
        guard cursor + length <= data.count else { return nil }

        if keepMarker {
            var value: UInt64 = 0
            for i in 0..<length {
                value = (value << 8) | UInt64(data[cursor + i])
            }
            return (value, length)
        }

        // Strip the marker bit from the first byte, then concatenate the rest.
        let markerMask: UInt8 = UInt8(0x80 >> (length - 1))
        let firstDataBits = first & ~markerMask
        var value: UInt64 = UInt64(firstDataBits)
        var allOnes = firstDataBits == (markerMask &- 1)
        if length > 1 {
            for i in 1..<length {
                let byte = data[cursor + i]
                value = (value << 8) | UInt64(byte)
                if byte != 0xFF { allOnes = false }
            }
        }
        return (allOnes ? nil : value, length)
    }

    /// Reads the data size vint at the cursor, advancing past it.
    public mutating func readSize() -> (size: Int?, length: Int)? {
        guard let (value, length) = peekVInt(keepMarker: false) else { return nil }
        cursor += length
        if let value { return (Int(truncatingIfNeeded: value), length) }
        return (nil, length)
    }

    /// Reads the element ID vint at the cursor, advancing past it. IDs in this
    /// reader fit in 32 bits (the Matroska elements we care about are ≤4 octets).
    public mutating func readID() -> UInt32? {
        guard let (value, length) = peekVInt(keepMarker: true), let value else { return nil }
        guard length <= 4 else {
            cursor += length
            return nil
        }
        cursor += length
        return UInt32(truncatingIfNeeded: value)
    }

    // MARK: - Element traversal

    /// One decoded element header at the cursor.
    public struct Element: Equatable {
        public let id: UInt32
        /// Local (`data`-relative) offset of the element's payload.
        public let localDataOffset: Int
        /// Payload size in bytes, or `nil` for unknown/streamed size.
        public let size: Int?
        /// Bytes consumed by the `[ID][size]` header.
        public let headerLength: Int

        public init(id: UInt32, localDataOffset: Int, size: Int?, headerLength: Int) {
            self.id = id
            self.localDataOffset = localDataOffset
            self.size = size
            self.headerLength = headerLength
        }
    }

    /// Reads the next element header at the cursor, advancing the cursor to the
    /// start of its payload. Returns `nil` at end-of-buffer or on truncation.
    public mutating func readElement() -> Element? {
        let start = cursor
        guard let id = readID() else { cursor = start; return nil }
        guard let (size, _) = readSize() else { cursor = start; return nil }
        let headerLength = cursor - start
        return Element(id: id, localDataOffset: cursor, size: size, headerLength: headerLength)
    }

    /// Advances the cursor past an element's payload (or to end-of-buffer for an
    /// unknown-size element).
    public mutating func skip(_ element: Element) {
        if let size = element.size {
            cursor = min(element.localDataOffset + size, data.count)
        } else {
            cursor = data.count
        }
    }

    // MARK: - Typed payload reads

    /// Reads an unsigned big-endian integer payload of `size` bytes at `offset`.
    public func uint(atLocal offset: Int, size: Int) -> UInt64? {
        guard size > 0, size <= 8, offset >= 0, offset + size <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<size {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    /// Reads an IEEE-754 float payload (4 or 8 bytes) at `offset`.
    public func double(atLocal offset: Int, size: Int) -> Double? {
        guard offset >= 0, offset + size <= data.count else { return nil }
        switch size {
        case 4:
            guard let bits = uint(atLocal: offset, size: 4) else { return nil }
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8:
            guard let bits = uint(atLocal: offset, size: 8) else { return nil }
            return Double(bitPattern: bits)
        case 0:
            return 0
        default:
            return nil
        }
    }

    /// Reads a raw binary payload of `size` bytes at `offset`.
    public func bytes(atLocal offset: Int, size: Int) -> [UInt8]? {
        guard size >= 0, offset >= 0, offset + size <= data.count else { return nil }
        return Array(data[offset..<(offset + size)])
    }

    /// Reads an ASCII/UTF-8 string payload of `size` bytes at `offset`,
    /// trimming embedded NULs.
    public func string(atLocal offset: Int, size: Int) -> String? {
        guard let raw = bytes(atLocal: offset, size: size) else { return nil }
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    // MARK: - Helpers

    /// Octet length implied by a vint's first byte (1...8).
    private func leadingZeroOctetLength(_ first: UInt8) -> Int {
        var mask: UInt8 = 0x80
        var length = 1
        while mask != 0 {
            if first & mask != 0 { return length }
            mask >>= 1
            length += 1
        }
        return 8
    }
}
