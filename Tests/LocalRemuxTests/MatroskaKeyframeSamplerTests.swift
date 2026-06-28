#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Byte-shape unit tests for `MatroskaKeyframeSampler` — the sparse keyframe
/// discovery primitive that walks Matroska EBML *structure* (Cluster headers,
/// Timecodes, block flags) without reading frame payloads. Fixtures are
/// hand-encoded EBML so the exact wire bytes are exercised with no network or
/// libavformat.
final class MatroskaKeyframeSamplerTests: XCTestCase {

    // MARK: - EBML fixture encoders

    /// Encodes an EBML data-size vint with the minimal byte count, keeping the
    /// length-marker bit (the decoder strips it back off).
    private func ebmlSize(_ n: Int) -> [UInt8] {
        var len = 1
        while len < 8 && UInt64(n) >= (UInt64(1) << (7 * len)) - 1 { len += 1 }
        var bytes = [UInt8](repeating: 0, count: len)
        var v = UInt64(n)
        var k = len - 1
        while k >= 0 { bytes[k] = UInt8(v & 0xFF); v >>= 8; k -= 1 }
        bytes[0] |= (0x80 >> (len - 1))
        return bytes
    }

    /// `[element-ID][data-size][data]`.
    private func el(_ id: [UInt8], _ data: [UInt8]) -> [UInt8] { id + ebmlSize(data.count) + data }

    /// Big-endian unsigned integer in the minimal number of bytes (≥1).
    private func uintBytes(_ v: UInt64) -> [UInt8] {
        if v == 0 { return [0] }
        var out: [UInt8] = []
        var x = v
        while x > 0 { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return out
    }

    // Canonical Matroska IDs (as their on-wire byte sequences).
    private let idEBMLHeader: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
    private let idSegment: [UInt8] = [0x18, 0x53, 0x80, 0x67]
    private let idInfo: [UInt8] = [0x15, 0x49, 0xA9, 0x66]
    private let idTimecodeScale: [UInt8] = [0x2A, 0xD7, 0xB1]
    private let idDuration: [UInt8] = [0x44, 0x89]
    private let idTracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B]
    private let idTrackEntry: [UInt8] = [0xAE]
    private let idTrackNumber: [UInt8] = [0xD7]
    private let idTrackType: [UInt8] = [0x83]
    private let idCluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    private let idTimecode: [UInt8] = [0xE7]
    private let idSimpleBlock: [UInt8] = [0xA3]
    private let idBlockGroup: [UInt8] = [0xA0]
    private let idBlock: [UInt8] = [0xA1]
    private let idReferenceBlock: [UInt8] = [0xFB]

    private func simpleBlock(track: Int, rel: Int16, keyframe: Bool, payload: [UInt8] = [0xAA, 0xBB]) -> [UInt8] {
        var d = ebmlSize(track)                       // track number is a vint
        let r = UInt16(bitPattern: rel)
        d.append(UInt8(r >> 8)); d.append(UInt8(r & 0xFF))
        d.append(keyframe ? 0x80 : 0x00)
        d += payload
        return el(idSimpleBlock, d)
    }

    private func blockGroup(track: Int, rel: Int16, hasReference: Bool, payload: [UInt8] = [0xAA]) -> [UInt8] {
        var d = ebmlSize(track)
        let r = UInt16(bitPattern: rel)
        d.append(UInt8(r >> 8)); d.append(UInt8(r & 0xFF))
        d.append(0x00)
        d += payload
        var body = el(idBlock, d)
        if hasReference { body += el(idReferenceBlock, [0x01]) }
        return el(idBlockGroup, body)
    }

    private func cluster(timecode: Int, blocks: [[UInt8]]) -> [UInt8] {
        var body = el(idTimecode, uintBytes(UInt64(timecode)))
        for b in blocks { body += b }
        return el(idCluster, body)
    }

    /// A complete single-video-track Matroska file: optional EBML header, Segment
    /// with Info (TimecodeScale + optional Duration) and Tracks (video track 1),
    /// followed by the given clusters.
    private func buildFile(timecodeScale: Int = 1_000_000, durationTicks: Int? = nil,
                           videoTrack: Int = 1, withEBMLHeader: Bool = true,
                           clusters: [[UInt8]]) -> [UInt8] {
        var info = el(idTimecodeScale, uintBytes(UInt64(timecodeScale)))
        if let d = durationTicks {
            // 8-byte IEEE double Duration.
            let bits = Double(d).bitPattern
            info += el(idDuration, (0..<8).reversed().map { UInt8((bits >> (8 * $0)) & 0xFF) })
        }
        let trackEntry = el(idTrackEntry,
                            el(idTrackNumber, uintBytes(UInt64(videoTrack)))
                            + el(idTrackType, [0x01])) // 1 = video
        var segBody = el(idInfo, info) + el(idTracks, trackEntry)
        for c in clusters { segBody += c }
        var file: [UInt8] = []
        if withEBMLHeader { file += el(idEBMLHeader, [0x42, 0x86, 0x81, 0x01]) }
        file += el(idSegment, segBody)
        return file
    }

    // MARK: - In-memory source

    private final class MemorySource: ByteRangeSource {
        let data: [UInt8]
        private(set) var fetches = 0
        init(_ d: [UInt8]) { data = d }
        var totalSize: Int64 { Int64(data.count) }
        func readRange(at offset: Int64, count: Int) -> Data {
            fetches += 1
            guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
            let start = Int(offset)
            let end = min(data.count, start + count)
            return Data(data[start..<end])
        }
    }

    // MARK: - EBML primitive tests

    func testElementID_lengthsAndMarkerKept() {
        XCTAssertEqual(EBML.elementID([0xE7], 0)?.id, 0xE7)            // 1-byte
        XCTAssertEqual(EBML.elementID([0xE7], 0)?.len, 1)
        XCTAssertEqual(EBML.elementID([0x44, 0x89], 0)?.id, 0x4489)   // 2-byte
        XCTAssertEqual(EBML.elementID([0x2A, 0xD7, 0xB1], 0)?.id, 0x2AD7B1) // 3-byte
        XCTAssertEqual(EBML.elementID([0x1F, 0x43, 0xB6, 0x75], 0)?.id, 0x1F43B675) // 4-byte
        XCTAssertNil(EBML.elementID([0x1F, 0x43], 0))                 // truncated
        XCTAssertNil(EBML.elementID([0x08], 0))                       // >4-byte lead, unsupported
    }

    func testVint_valueStripsMarker_andUnknownSentinel() {
        XCTAssertEqual(EBML.vint([0x81], 0)?.value, 1)
        XCTAssertEqual(EBML.vint([0x81], 0)?.len, 1)
        XCTAssertEqual(EBML.vint([0x40, 0xC8], 0)?.value, 200)
        XCTAssertEqual(EBML.vint([0x40, 0xC8], 0)?.len, 2)
        XCTAssertEqual(EBML.vint([0xFF], 0)?.unknown, true)   // 1-byte all-ones
        XCTAssertEqual(EBML.vint([0x7F, 0xFF], 0)?.unknown, true) // 2-byte all-ones
        XCTAssertEqual(EBML.vint([0x81], 0)?.unknown, false)
        XCTAssertNil(EBML.vint([0x00], 0))                    // invalid leading byte
    }

    func testUintAndFloat() {
        XCTAssertEqual(EBML.uint([0x01, 0x00], 0, 2), 256)
        XCTAssertEqual(EBML.uint([0xFF, 0xFF, 0xFF], 0, 3), 0xFFFFFF)
        let bits = Double(1.5).bitPattern
        let f8 = (0..<8).reversed().map { UInt8((bits >> (8 * $0)) & 0xFF) }
        XCTAssertEqual(EBML.float(f8, 0, 8), 1.5)
    }

    func testBlockHeader_keyframeFlagAndTrack() {
        let kf = simpleBlock(track: 1, rel: 0, keyframe: true)
        // The block *data* begins after the SimpleBlock element header (ID + size).
        let dataStart = idSimpleBlock.count + ebmlSize(kf.count - idSimpleBlock.count - ebmlSize(0).count).count
        // Simpler: parse from the known offset by re-encoding just the data.
        var blockData = ebmlSize(1)
        blockData.append(0x00); blockData.append(0x00) // rel 0
        blockData.append(0x80)                          // keyframe
        let h = MatroskaBlockHeader.parse(blockData, 0)
        XCTAssertEqual(h?.track, 1)
        XCTAssertEqual(h?.relTimecode, 0)
        XCTAssertEqual(h?.isKeyframe, true)
        _ = dataStart

        var nonKF = ebmlSize(2)
        nonKF.append(0x00); nonKF.append(0x10)  // rel +16
        nonKF.append(0x00)                       // not a keyframe
        let h2 = MatroskaBlockHeader.parse(nonKF, 0)
        XCTAssertEqual(h2?.track, 2)
        XCTAssertEqual(h2?.relTimecode, 16)
        XCTAssertEqual(h2?.isKeyframe, false)
    }

    // MARK: - Init parsing

    func testParseInit_extractsTrackScaleDurationAndFirstCluster() {
        let file = buildFile(timecodeScale: 1_000_000, durationTicks: 6000, videoTrack: 1,
                             clusters: [cluster(timecode: 0, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])])
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        let info = sampler.parseInit()
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.videoTrack, 1)
        XCTAssertEqual(info?.timecodeScale, 1_000_000)
        XCTAssertEqual(info?.durationSeconds ?? 0, 6.0, accuracy: 1e-9)
        XCTAssertGreaterThan(info?.firstClusterOffset ?? -1, 0)
    }

    func testParseInit_worksWithoutEBMLHeaderElement() {
        let file = buildFile(withEBMLHeader: false,
                             clusters: [cluster(timecode: 0, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])])
        let info = MatroskaKeyframeSampler(source: MemorySource(file)).parseInit()
        XCTAssertEqual(info?.videoTrack, 1)
    }

    // MARK: - Cluster walk / keyframes

    func testAllKeyframes_oneKeyframePerClusterAtClusterTimecode() {
        // Clusters at 0s, 2s, 4.5s, 7s (scale 1ms → timecode == ms).
        let clusters = [
            cluster(timecode: 0,    blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
            cluster(timecode: 2000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
            cluster(timecode: 4500, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
            cluster(timecode: 7000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
        ]
        let file = buildFile(durationTicks: 9000, clusters: clusters)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let kf = sampler.allKeyframes(info)
        XCTAssertEqual(kf, [0.0, 2.0, 4.5, 7.0])
    }

    func testKeyframe_skipsLeadingAudioBlockToFindVideoKeyframe() {
        // Cluster begins with an audio block (track 2), then the video keyframe at rel +10ms.
        let c = cluster(timecode: 3000, blocks: [
            simpleBlock(track: 2, rel: 0, keyframe: true, payload: [0x01, 0x02]),
            simpleBlock(track: 1, rel: 10, keyframe: true, payload: [0x03, 0x04]),
        ])
        let file = buildFile(clusters: [c])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let kf = sampler.allKeyframes(info)
        XCTAssertEqual(kf.count, 1)
        XCTAssertEqual(kf[0], 3.010, accuracy: 1e-9)
    }

    func testKeyframe_nonScaledTimecodeScale() {
        // 500_000 ns/tick → each tick is 0.5 ms; timecode 4000 → 2.0 s.
        let c = cluster(timecode: 4000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])
        let file = buildFile(timecodeScale: 500_000, clusters: [c])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        XCTAssertEqual(sampler.allKeyframes(info), [2.0])
    }

    func testBlockGroup_keyframeWhenNoReferenceBlock() {
        let kfCluster = cluster(timecode: 1000, blocks: [blockGroup(track: 1, rel: 0, hasReference: false)])
        let file = buildFile(clusters: [kfCluster])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        XCTAssertEqual(sampler.allKeyframes(info), [1.0])
    }

    func testWalkClusters_resumableWindowing() {
        let clusters = (0..<10).map { i in
            cluster(timecode: i * 1000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])
        }
        let file = buildFile(durationTicks: 10000, clusters: clusters)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }

        var out: [Double] = []
        var state = MatroskaKeyframeSampler.WalkState(clusterOffset: info.firstClusterOffset, done: false)
        // First window: up to 3s.
        _ = sampler.walkClusters(info, state: &state, untilSeconds: 3.0, into: &out)
        XCTAssertEqual(out, [0.0, 1.0, 2.0, 3.0])
        XCTAssertFalse(state.done)
        // Resume to EOF.
        _ = sampler.walkClusters(info, state: &state, untilSeconds: nil, into: &out)
        XCTAssertEqual(out, [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0])
        XCTAssertTrue(state.done)
    }

    func testWalk_isLowByte_relativeToFileSize() {
        // Pad each cluster with a large fake payload so the file is "big" but the
        // walk only reads cluster headers — proving the O(structure) byte cost.
        let bigPayload = [UInt8](repeating: 0x77, count: 200_000)
        let clusters = (0..<20).map { i in
            cluster(timecode: i * 1000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true, payload: bigPayload)])
        }
        let file = buildFile(durationTicks: 20000, clusters: clusters)
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let kf = sampler.allKeyframes(info)
        XCTAssertEqual(kf.count, 20)
        // Header-only walk must read far less than the whole (≈4MB) file.
        XCTAssertLessThan(sampler.stats.bytesRead, file.count / 4)
    }

    // MARK: - Unknown-size cluster → sync scan fallback

    func testUnknownSizeCluster_syncScanFindsNextCluster() {
        // Hand-build two clusters where the FIRST declares unknown size (all-ones),
        // forcing the walker to sync-scan for the second cluster's start.
        func unknownSizeCluster(timecode: Int, blocks: [[UInt8]]) -> [UInt8] {
            var body = el(idTimecode, uintBytes(UInt64(timecode)))
            for b in blocks { body += b }
            return idCluster + [0xFF] + body  // 0xFF = unknown-size vint
        }
        let c0 = unknownSizeCluster(timecode: 0, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])
        let c1 = cluster(timecode: 5000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])
        let file = buildFile(durationTicks: 8000, clusters: [c0, c1])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file), scanChunk: 64)
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let kf = sampler.allKeyframes(info)
        XCTAssertEqual(kf, [0.0, 5.0])
        XCTAssertGreaterThan(sampler.stats.syncScans, 0)
    }

    // MARK: - Robustness

    func testNonMatroskaSource_returnsNil() {
        let junk = MemorySource([UInt8](repeating: 0x00, count: 64))
        XCTAssertNil(MatroskaKeyframeSampler(source: junk).parseInit())
    }

    func testMonotonic_dropsDuplicateOrBackwardClusterTimes() {
        // A degenerate file with a backward/duplicate cluster timecode must not
        // emit a non-increasing boundary.
        let clusters = [
            cluster(timecode: 0,    blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
            cluster(timecode: 2000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
            cluster(timecode: 2000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]), // dup
            cluster(timecode: 1000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]), // backward
            cluster(timecode: 4000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)]),
        ]
        let file = buildFile(durationTicks: 5000, clusters: clusters)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let kf = sampler.allKeyframes(info)
        XCTAssertEqual(kf, [0.0, 2.0, 4.0])
    }
    // MARK: - keyframeBoundary(near:) per-seek primitive

    /// Builds the standard 20-cluster, large-payload file used by the seek tests:
    /// clusters at 0s,1s,…,19s, each padded so the file is ~4 MB and a byte-offset
    /// estimate maps roughly linearly to time (≈CBR).
    private func bigSeekFile(payloadBytes: Int = 200_000) -> [UInt8] {
        let pad = [UInt8](repeating: 0x77, count: payloadBytes)
        let clusters = (0..<20).map { i in
            cluster(timecode: i * 1000, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true, payload: pad)])
        }
        return buildFile(durationTicks: 20000, clusters: clusters)
    }

    func testKeyframeBoundary_snapsToEnclosingKeyframe_lowByte() {
        let file = bigSeekFile()
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        // Seek to 10.4s with a ~one-cluster margin so the byte estimate (not a
        // from-start walk) does the work: must snap to the 10.0s keyframe.
        let hit = sampler.keyframeBoundary(near: 10.4, info: info, marginBytes: 250_000)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.startSeconds ?? -1, 10.0, accuracy: 1e-9)
        // The estimate must have skipped the early clusters → genuinely low-byte.
        XCTAssertLessThan(sampler.stats.bytesRead, file.count / 4)
        XCTAssertLessThan(src.fetches, 25)
    }

    func testKeyframeBoundary_exactBoundaryReturnsThatCluster() {
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        XCTAssertEqual(sampler.keyframeBoundary(near: 5.0, info: info, marginBytes: 250_000)?.startSeconds ?? -1,
                       5.0, accuracy: 1e-9)
    }

    func testKeyframeBoundary_targetBeforeFirstReturnsFirst() {
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        XCTAssertEqual(sampler.keyframeBoundary(near: 0.0, info: info)?.startSeconds ?? -1,
                       0.0, accuracy: 1e-9)
    }

    func testKeyframeBoundary_targetPastEndClampsToLast() {
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        // 100s clamps to the 20s duration → last keyframe is 19.0s.
        XCTAssertEqual(sampler.keyframeBoundary(near: 100.0, info: info, marginBytes: 250_000)?.startSeconds ?? -1,
                       19.0, accuracy: 1e-9)
    }

    func testKeyframeBoundary_offsetIsSeekable() {
        // The returned clusterOffset must itself be a Cluster element start whose
        // timecode is the reported boundary — i.e. directly usable as a muxer seek.
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        guard let hit = sampler.keyframeBoundary(near: 12.7, info: info, marginBytes: 250_000) else {
            return XCTFail("no boundary")
        }
        XCTAssertEqual(hit.startSeconds, 12.0, accuracy: 1e-9)
        // Re-walk from the returned offset: the first keyframe there is 12.0s.
        var out: [Double] = []
        var st = MatroskaKeyframeSampler.WalkState(clusterOffset: hit.clusterOffset, done: false)
        _ = sampler.walkClusters(info, state: &st, untilSeconds: 12.0, into: &out)
        XCTAssertEqual(out.first ?? -1, 12.0, accuracy: 1e-9)
    }

    func testKeyframeBoundary_unknownTotalSizeReturnsNil() {
        final class UnsizedSource: ByteRangeSource {
            let data: [UInt8]
            init(_ d: [UInt8]) { data = d }
            var totalSize: Int64 { -1 }   // server didn't advertise a length
            func readRange(at offset: Int64, count: Int) -> Data {
                guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
                return Data(data[Int(offset)..<min(data.count, Int(offset) + count)])
            }
        }
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: UnsizedSource(file))
        // parseInit may still work, but a byte-fraction seek needs a known size.
        let info = MatroskaKeyframeSampler.InitInfo(videoTrack: 1, timecodeScale: 1_000_000,
            durationSeconds: 20.0, segmentDataOffset: 0, firstClusterOffset: 0)
        XCTAssertNil(sampler.keyframeBoundary(near: 10.0, info: info))
    }
}
#endif
