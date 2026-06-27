import Foundation

/// A parsed Roku **BIF** ("Base Index Frames") trickplay file — the format Plex
/// serves at `/library/parts/{partId}/indexes/sd` for scrubbing previews.
///
/// A BIF blob is a 64-byte header followed by an index table and then the raw
/// JPEG frames concatenated back-to-back. This type parses the header + index so
/// the player can slice out the JPEG bytes for any scrub position without
/// decoding the live stream.
///
/// ## Frame timing (why we read each entry's timestamp)
/// Per the Roku spec, the header's "framewise separation" is a **multiplier**,
/// not the literal frame interval: a frame's real playback time in milliseconds
/// is `framewiseSeparation × (the timestamp stored in that frame's index entry)`.
/// For a simple evenly-spaced file the entry timestamps are `0, 1, 2, …`, so the
/// real interval equals the separation — but that is **not** guaranteed. Plex, in
/// particular, writes entry timestamps that stride by more than one (e.g. `0, 2,
/// 4, …`), making the true interval a multiple of the header value. Assuming the
/// timestamp is simply the frame index (`i × separation`) therefore runs the
/// preview clock too fast and shows late frames at early scrub positions, so we
/// read each entry's real timestamp and look frames up by playback time.
///
/// Layout (all multi-byte integers little-endian):
///  * `0x00…0x07` magic `89 42 49 46 0D 0A 1A 0A`
///  * `0x08` version (u32)
///  * `0x0C` number of frames *N* (u32)
///  * `0x10` framewise separation / timestamp multiplier in ms (u32; `0` ⇒ 1000)
///  * `0x14…0x3F` reserved
///  * `0x40` index: `N + 1` entries of `[timestamp u32][absolute offset u32]`;
///    the trailing entry is the end-of-data sentinel, so frame *i* spans
///    `offset[i]..<offset[i+1]` and covers `timestamp[i] × separation` ms.
public struct BIFIndex: Equatable, Sendable {
    /// One indexed preview frame: where its JPEG lives inside the BIF blob.
    public struct Frame: Equatable, Sendable {
        /// Playback time this frame represents, in milliseconds.
        public var timestampMs: Int
        /// Absolute byte offset of the JPEG within the BIF blob.
        public var offset: Int
        /// JPEG byte length.
        public var length: Int

        public init(timestampMs: Int, offset: Int, length: Int) {
            self.timestampMs = timestampMs
            self.offset = offset
            self.length = length
        }

        /// The half-open byte range of this frame's JPEG within the blob.
        public var range: Range<Int> { offset..<(offset + length) }
    }

    /// Milliseconds of playback the header advertises between consecutive frames.
    /// This is the spec's "framewise separation" multiplier; each frame's real
    /// time is `timestampMs`, derived from its own index-entry timestamp. Kept for
    /// diagnostics and as the multiplier used during parsing.
    public var framewiseSeparationMs: Int
    /// Every preview frame, in playback order (ascending `timestampMs`).
    public var frames: [Frame]

    /// The 8-byte BIF magic number.
    public static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let headerSize = 64
    private static let indexEntrySize = 8

    public init(framewiseSeparationMs: Int, frames: [Frame]) {
        self.framewiseSeparationMs = framewiseSeparationMs
        self.frames = frames
    }

    /// Parses a BIF blob, or returns `nil` if the bytes aren't a valid BIF with
    /// at least one resolvable frame.
    public init?(data: Data) {
        // A contiguous byte view, so subscripting is 0-based regardless of the
        // original `Data`'s slice indices.
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<8]) == Self.magic else { return nil }

        func u32(_ offset: Int) -> Int {
            Int(UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24))
        }

        let count = u32(0x0C)
        // A zero separation is the documented "unset" case; fall back to 1s.
        let separation = u32(0x10) == 0 ? 1000 : u32(0x10)
        guard count > 0 else { return nil }

        // We read each frame's offset plus the next entry's offset (for length),
        // so the index needs N + 1 entries.
        let indexBytesNeeded = Self.headerSize + (count + 1) * Self.indexEntrySize
        guard bytes.count >= indexBytesNeeded else { return nil }

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            let entry = Self.headerSize + i * Self.indexEntrySize
            // Each entry is [timestamp u32][absolute offset u32]; the next entry's
            // offset bounds this frame's JPEG. The frame's real playback time is
            // its own timestamp × the separation multiplier — never assume the
            // timestamp equals the loop index (Plex strides by more than one).
            let entryTimestamp = u32(entry)
            let offset = u32(entry + 4)
            let nextOffset = u32(entry + Self.indexEntrySize + 4)
            let length = nextOffset - offset
            // Skip malformed/empty entries rather than failing the whole parse.
            guard length > 0, offset >= 0, nextOffset <= bytes.count else { continue }
            // Clamp on overflow so a hostile/corrupt index can't trap: both
            // factors are u32-sized, and u32 × u32 (max ≈1.8e19) exceeds Int.max
            // (≈9.2e18) even on 64-bit, so the product genuinely can overflow.
            let (product, overflow) = entryTimestamp.multipliedReportingOverflow(by: separation)
            let timestampMs = overflow ? Int.max : product
            frames.append(Frame(timestampMs: timestampMs, offset: offset, length: length))
        }
        guard !frames.isEmpty else { return nil }

        self.framewiseSeparationMs = separation
        self.frames = frames
    }

    /// The frame index covering a playback position (clamped to range), or `nil`
    /// when there are no frames. Finds the latest frame whose real timestamp is at
    /// or before `seconds`, so previews stay aligned even when frames aren't spaced
    /// at exactly `framewiseSeparationMs` (e.g. Plex's strided entry timestamps).
    public func frameIndex(forSeconds seconds: TimeInterval) -> Int? {
        guard !frames.isEmpty else { return nil }
        let ms = Int((max(0, seconds) * 1000).rounded(.down))
        // Frames are in ascending timestamp order; binary-search for the rightmost
        // frame with timestampMs <= ms.
        var low = 0
        var high = frames.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].timestampMs <= ms {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// The frame covering a playback position, or `nil` when unavailable.
    public func frame(forSeconds seconds: TimeInterval) -> Frame? {
        guard let index = frameIndex(forSeconds: seconds) else { return nil }
        return frames[index]
    }
}
