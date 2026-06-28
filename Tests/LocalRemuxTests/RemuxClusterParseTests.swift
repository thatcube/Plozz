#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_test_parse_cluster_keyframe` — the Matroska
/// cluster/Block HEADER parser behind the `com.plozz.playback.remuxKeyframeIndex`
/// open-latency fix. Discovery uses it to read each boundary keyframe's raw
/// (TimestampScale-unit) timestamp = clusterTimestamp + block relative ts straight
/// out of a few-KB cluster header, instead of demuxing the whole keyframe packet
/// (~one 4K IDR ≈ 1+ MiB). These tests feed it hand-built EBML/Matroska bytes (no
/// I/O, no demux) and assert it returns the first VIDEO keyframe's raw timestamp —
/// and importantly, that it REFUSES (returns 0) on anything it can't positively
/// parse, since the C caller falls back to av_read_frame on a 0, never corrupting a
/// boundary.
final class RemuxClusterParseTests: XCTestCase {

    // MARK: - EBML byte builders

    /// Encode an EBML variable-length integer of exactly `length` bytes with the
    /// leading length-marker bit set (matches matroska size/track encoding).
    private func vint(_ value: UInt64, length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        var v = value
        for i in stride(from: length - 1, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0xFF); v >>= 8
        }
        bytes[0] |= UInt8(0x80) >> (length - 1)
        return bytes
    }

    /// Element ID bytes (already carry their marker bits; emit big-endian, trimmed
    /// to the minimal whole-byte width the ID needs).
    private func id(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var started = false
        for shift in stride(from: 24, through: 0, by: -8) {
            let b = UInt8((value >> UInt32(shift)) & 0xFF)
            if b != 0 || started || shift == 0 { out.append(b); started = true }
        }
        return out
    }

    private func be(_ value: UInt64, bytes: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes)
        var v = value
        for i in stride(from: bytes - 1, through: 0, by: -1) { out[i] = UInt8(v & 0xFF); v >>= 8 }
        return out
    }

    /// A (Simple)Block body: track vint + 2-byte BE signed rel-ts + flags + payload.
    private func blockBody(track: UInt64, rel: Int16, flags: UInt8, payload: Int = 8) -> [UInt8] {
        var b = vint(track, length: 1)
        let r = UInt16(bitPattern: rel)
        b.append(UInt8(r >> 8)); b.append(UInt8(r & 0xFF))
        b.append(flags)
        b.append(contentsOf: [UInt8](repeating: 0xAA, count: payload))
        return b
    }

    private func element(_ elemID: UInt32, _ body: [UInt8], sizeLen: Int = 1) -> [UInt8] {
        var e = id(elemID)
        e.append(contentsOf: vint(UInt64(body.count), length: sizeLen))
        e.append(contentsOf: body)
        return e
    }

    /// Wrap children as a Cluster element with a definite size (default) or the
    /// "unknown size" all-ones sentinel.
    private func cluster(_ children: [UInt8], unknownSize: Bool = false, sizeLen: Int = 2) -> [UInt8] {
        var c = id(0x1F43B675)
        if unknownSize {
            c.append(contentsOf: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) // 8-byte unknown
        } else {
            c.append(contentsOf: vint(UInt64(children.count), length: sizeLen))
        }
        c.append(contentsOf: children)
        return c
    }

    private func parse(_ buf: [UInt8], videoTrack: Int64) -> Int64? {
        var raw: Int64 = -123456
        let ok = buf.withUnsafeBufferPointer {
            plozz_remux_test_parse_cluster_keyframe($0.baseAddress, Int32(buf.count), videoTrack, &raw)
        }
        return ok == 1 ? raw : nil
    }

    private let TIMESTAMP: UInt32 = 0xE7
    private let SIMPLEBLOCK: UInt32 = 0xA3
    private let BLOCKGROUP: UInt32 = 0xA0
    private let BLOCK: UInt32 = 0xA1
    private let REFBLOCK: UInt32 = 0xFB

    // MARK: - Happy path

    func testSingleKeyframeSimpleBlock() {
        var kids = element(TIMESTAMP, be(5000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 7, flags: 0x80))
        let raw = parse(cluster(kids), videoTrack: 1)
        XCTAssertEqual(raw, 5007) // clusterTS + rel
    }

    func testSkipsNonKeyframeBlockThenFindsKeyframe() {
        var kids = element(TIMESTAMP, be(10000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 0, flags: 0x00))   // not keyframe
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 42, flags: 0x80))  // keyframe
        XCTAssertEqual(parse(cluster(kids), videoTrack: 1), 10042)
    }

    func testIgnoresOtherTrackKeyframe() {
        var kids = element(TIMESTAMP, be(2000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 2, rel: 1, flags: 0x80))   // audio keyframe
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 3, flags: 0x80))   // video keyframe
        XCTAssertEqual(parse(cluster(kids), videoTrack: 1), 2003)
    }

    func testNegativeRelativeTimestamp() {
        var kids = element(TIMESTAMP, be(8000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: -25, flags: 0x80))
        XCTAssertEqual(parse(cluster(kids), videoTrack: 1), 7975)
    }

    func testMultiByteTimestampAndSizes() {
        // 8-byte cluster ts, longer size vints — exercises vint length decoding.
        var kids = element(TIMESTAMP, be(123456789, bytes: 4), sizeLen: 2)
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 11, flags: 0x80), sizeLen: 4)
        XCTAssertEqual(parse(cluster(kids, sizeLen: 4), videoTrack: 1), 123456800)
    }

    func testUnknownClusterSize() {
        var kids = element(TIMESTAMP, be(6000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 9, flags: 0x80))
        XCTAssertEqual(parse(cluster(kids, unknownSize: true), videoTrack: 1), 6009)
    }

    // MARK: - BlockGroup

    func testBlockGroupWithoutReferenceIsKeyframe() {
        let inner = element(BLOCK, blockBody(track: 1, rel: 4, flags: 0x00))
        var kids = element(TIMESTAMP, be(3000, bytes: 2))
        kids += element(BLOCKGROUP, inner)
        XCTAssertEqual(parse(cluster(kids), videoTrack: 1), 3004)
    }

    func testBlockGroupWithReferenceIsNotKeyframe() {
        var inner = element(BLOCK, blockBody(track: 1, rel: 4, flags: 0x00))
        inner += element(REFBLOCK, be(0xFF, bytes: 1)) // ReferenceBlock present → P-frame
        var kids = element(TIMESTAMP, be(3000, bytes: 2))
        kids += element(BLOCKGROUP, inner)
        XCTAssertNil(parse(cluster(kids), videoTrack: 1)) // no keyframe → caller falls back
    }

    // MARK: - Refusals (must return 0 so the caller uses av_read_frame)

    func testRejectsNonClusterBuffer() {
        // Starts with a Timestamp element, not a Cluster ID.
        let buf = element(TIMESTAMP, be(1000, bytes: 2))
        XCTAssertNil(parse(buf, videoTrack: 1))
    }

    func testRejectsClusterWithNoVideoKeyframe() {
        var kids = element(TIMESTAMP, be(1000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 1, flags: 0x00)) // only non-keyframe
        XCTAssertNil(parse(cluster(kids), videoTrack: 1))
    }

    func testRejectsTruncatedWindowBeforeKeyframe() {
        var kids = element(TIMESTAMP, be(1000, bytes: 2))
        kids += element(SIMPLEBLOCK, blockBody(track: 1, rel: 5, flags: 0x80))
        let full = cluster(kids)
        // Drop payload(8)+flags(1) so the block header is incomplete (no keyframe
        // flag readable) — parser must refuse rather than guess.
        let cut = Array(full.prefix(full.count - 9))
        XCTAssertNil(parse(cut, videoTrack: 1))
    }

    func testRejectsEmptyAndTinyBuffers() {
        XCTAssertNil(parse([], videoTrack: 1))
        XCTAssertNil(parse([0x1F], videoTrack: 1))
    }
}

/// Pure-logic tests for `plozz_remux_test_find_cluster_sync` — the resync that lets
/// the header-parse path tolerate a libav cursor a no-Cues BACKWARD seek leaves a few
/// bytes PAST the Cluster header. It scans a small window read just BEFORE the cursor
/// and returns the offset of the nearest Cluster sync (0x1F43B675) at/<= the anchor,
/// else the first after it, else -1. Without this, every probe missed and discovery
/// fell back to ~1 MiB av_read_frame reads (the 13%-coverage bug).
final class RemuxClusterSyncTests: XCTestCase {

    private func find(_ buf: [UInt8], anchor: Int) -> Int {
        return buf.withUnsafeBufferPointer {
            Int(plozz_remux_test_find_cluster_sync($0.baseAddress, Int32(buf.count), Int32(anchor)))
        }
    }

    private let SYNC: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]

    func testSyncExactlyAtAnchor() {
        // Cursor landed exactly on the cluster header.
        var buf = [UInt8](repeating: 0x00, count: 8)
        buf += SYNC
        buf += [UInt8](repeating: 0x11, count: 8)
        XCTAssertEqual(find(buf, anchor: 8), 8)
    }

    func testSyncJustBeforeAnchor() {
        // The real bug: seek left the cursor a few bytes past the header → anchor is
        // inside the cluster; resync must walk BACK to the header at offset 8.
        var buf = [UInt8](repeating: 0x00, count: 8)
        buf += SYNC
        buf += [UInt8](repeating: 0x22, count: 64)
        XCTAssertEqual(find(buf, anchor: 20), 8)
    }

    func testPrefersLatestSyncAtOrBeforeAnchor() {
        // Two clusters in the window; the keyframe at the cursor belongs to the LATER
        // one, so the resync must pick the latest sync <= anchor, not the first.
        var buf = SYNC                                   // cluster A @ 0
        buf += [UInt8](repeating: 0x33, count: 30)
        let bAt = buf.count                              // cluster B @ 34
        buf += SYNC
        buf += [UInt8](repeating: 0x44, count: 30)
        XCTAssertEqual(find(buf, anchor: bAt + 5), bAt)
    }

    func testFallsForwardWhenNoSyncPrecedesAnchor() {
        // No sync at/<= anchor → take the first sync AFTER it rather than failing.
        var buf = [UInt8](repeating: 0x00, count: 10)
        let at = buf.count
        buf += SYNC
        XCTAssertEqual(find(buf, anchor: 3), at)
    }

    func testReturnsMinusOneWhenNoSync() {
        let buf = [UInt8](repeating: 0x5A, count: 64)
        XCTAssertEqual(find(buf, anchor: 32), -1)
    }

    func testIgnoresPartialSyncAtBufferEnd() {
        // A truncated 3-byte prefix of the sync at the tail must not match.
        var buf = [UInt8](repeating: 0x00, count: 16)
        buf += [0x1F, 0x43, 0xB6] // partial, no 0x75
        XCTAssertEqual(find(buf, anchor: 16), -1)
    }

    func testAnchorBeyondBufferClampsToLatestSync() {
        // Defensive: an anchor past the buffer still returns the latest sync present.
        var buf = [UInt8](repeating: 0x00, count: 4)
        buf += SYNC
        XCTAssertEqual(find(buf, anchor: 9999), 4)
    }
}
#endif
