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
    private let idSeekHead: [UInt8] = [0x11, 0x4D, 0x9B, 0x74]
    private let idSeek: [UInt8] = [0x4D, 0xBB]
    private let idSeekID: [UInt8] = [0x53, 0xAB]
    private let idSeekPosition: [UInt8] = [0x53, 0xAC]
    private let idCues: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
    private let idCuePoint: [UInt8] = [0xBB]
    private let idCueTime: [UInt8] = [0xB3]
    private let idCueTrackPositions: [UInt8] = [0xB7]
    private let idCueTrack: [UInt8] = [0xF7]
    private let idCueClusterPosition: [UInt8] = [0xF1]

    /// Fixed-width (8-byte) big-endian uint, so SeekPosition/CueClusterPosition keep
    /// a constant encoded length regardless of value — lets the file builder compute
    /// element offsets in one pass without a fixpoint over vint widths.
    private func u64be(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) } }

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

    /// A SeekHead element naming the Cues byte position (Segment-data-relative).
    private func seekHead(cuesPos: UInt64) -> [UInt8] {
        let seek = el(idSeek, el(idSeekID, idCues) + el(idSeekPosition, u64be(cuesPos)))
        return el(idSeekHead, seek)
    }

    /// A Cues element from (timeTicks, [(track, segRelClusterPos)]) entries. Each
    /// CuePoint may carry multiple CueTrackPositions to exercise track filtering.
    private func cues(_ entries: [(time: Int, positions: [(track: Int, pos: Int)])]) -> [UInt8] {
        var body: [UInt8] = []
        for e in entries {
            var cp = el(idCueTime, uintBytes(UInt64(e.time)))
            for p in e.positions {
                cp += el(idCueTrackPositions,
                         el(idCueTrack, uintBytes(UInt64(p.track)))
                         + el(idCueClusterPosition, u64be(UInt64(p.pos))))
            }
            body += el(idCuePoint, cp)
        }
        return el(idCues, body)
    }

    /// Builds a single-video-track file laid out as a real muxer would for the
    /// Cues fast-path: SeekHead at the Segment front pointing at a TRAILING Cues
    /// element after all clusters. Returns the file plus the expected keyframe
    /// seconds and the Segment-data-relative cluster offsets so tests can assert
    /// both PTS and absolute byte offsets end-to-end.
    private func buildFileWithCues(timecodeScale: Int = 1_000_000, durationTicks: Int? = nil,
                                   videoTrack: Int = 1, clusterTimes: [Int],
                                   payloadBytes: Int = 2,
                                   extraPositions: [(track: Int, pos: Int)] = []) ->
        (file: [UInt8], keyframeSeconds: [Double], clusterRelOffsets: [Int]) {
        var infoData = el(idTimecodeScale, uintBytes(UInt64(timecodeScale)))
        if let d = durationTicks {
            let bits = Double(d).bitPattern
            infoData += el(idDuration, (0..<8).reversed().map { UInt8((bits >> (8 * $0)) & 0xFF) })
        }
        let infoEl = el(idInfo, infoData)
        let tracksEl = el(idTracks, el(idTrackEntry,
                          el(idTrackNumber, uintBytes(UInt64(videoTrack))) + el(idTrackType, [0x01])))
        let pad = [UInt8](repeating: 0x77, count: max(2, payloadBytes))
        let clusterEls = clusterTimes.map {
            cluster(timecode: $0, blocks: [simpleBlock(track: videoTrack, rel: 0, keyframe: true, payload: pad)])
        }
        let shLen = seekHead(cuesPos: 0).count // fixed-width SeekPosition → stable length
        let infoOff = shLen
        let tracksOff = infoOff + infoEl.count
        var clusterRelOffsets: [Int] = []
        var run = tracksOff + tracksEl.count
        for c in clusterEls { clusterRelOffsets.append(run); run += c.count }
        let cuesRelOff = run
        let entries = zip(clusterTimes, clusterRelOffsets).map { t, off in
            (time: t, positions: [(track: videoTrack, pos: off)] + extraPositions)
        }
        let sh = seekHead(cuesPos: UInt64(cuesRelOff))
        XCTAssertEqual(sh.count, shLen, "SeekHead width must be stable")
        var segBody = sh + infoEl + tracksEl
        for c in clusterEls { segBody += c }
        segBody += cues(entries)
        var file: [UInt8] = el(idEBMLHeader, [0x42, 0x86, 0x81, 0x01])
        file += el(idSegment, segBody)
        let kf = clusterTimes.map { Double($0) * Double(timecodeScale) / 1e9 }
        return (file, kf, clusterRelOffsets)
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

    // MARK: - discoverKeyframe(at:) phase-2 façade

    func testDiscoverKeyframe_matchesKeyframeBoundary() {
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let hit = sampler.discoverKeyframe(at: 13.3, info: info)
        XCTAssertEqual(hit?.startSeconds ?? -1, 13.0, accuracy: 1e-9)
        // Same answer as the underlying primitive, packaged as a named type.
        let raw = sampler.keyframeBoundary(near: 13.3, info: info)
        XCTAssertEqual(hit?.clusterOffset, raw?.clusterOffset)
    }

    // MARK: - PTS correctness vs an INDEPENDENT keyframe-time oracle

    /// The walker's reported keyframe PTS must equal the TRUE keyframe presentation
    /// time computed independently as (clusterTimecode + blockRelTimecode) ×
    /// timecodeScale — with a realistic non-1 ms scale, NTSC-style non-uniform
    /// timecodes, a non-zero block rel-timecode, and an interleaved audio block the
    /// walker must skip. This is the "walker PTS == real keyframe PTS" assertion
    /// the lazy engine's in-sync seek depends on: if this math were off, every
    /// far-seek would land off-keyframe and desync.
    func testWalkerPTS_equalsIndependentOracle_realisticTimecodes() {
        let scale = 1_000_000 // 1 ms ticks
        // NTSC 23.976-ish: ~6.006 s GOPs. clusterTC in ms ticks; +1 ms block rel.
        let clusterTCs = [0, 6006, 12012, 18018, 24024]
        let rel: Int16 = 1
        let clusters = clusterTCs.map { tc in
            cluster(timecode: tc, blocks: [
                // An audio block (track 2) FIRST — the walker must skip it.
                simpleBlock(track: 2, rel: 0, keyframe: true, payload: [0x01, 0x02]),
                // The video keyframe (track 1) at +rel.
                simpleBlock(track: 1, rel: rel, keyframe: true, payload: [0xAA, 0xBB])
            ])
        }
        let file = buildFile(timecodeScale: scale, durationTicks: 30030,
                             videoTrack: 1, clusters: clusters)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let walked = sampler.allKeyframes(info)
        // Independent oracle: PTS = (clusterTC + rel) × scale / 1e9 seconds.
        let oracle = clusterTCs.map { Double($0 + Int(rel)) * Double(scale) / 1_000_000_000 }
        XCTAssertEqual(walked.count, oracle.count)
        for (w, o) in zip(walked, oracle) { XCTAssertEqual(w, o, accuracy: 1e-9) }
    }

    // MARK: - Cost on LARGE 4K-style clusters (the case that broke B6)

    /// On a file with multi-MB clusters (a 4K title's ~6 s GOP is megabytes), a
    /// single far-seek probe must read a BOUNDED amount — at most ~one cluster for
    /// the cold landing sync plus a few small header probes — NOT the whole file,
    /// and NOT the ~1 MiB-per-boundary av_read_frame payload B6 paid. The walker
    /// never transfers a frame payload: it size-skips known-size clusters by their
    /// element length.
    func testKeyframeBoundary_largeClusters_boundedBytesPerProbe() {
        let payload = 4_000_000 // ~4 MB cluster payloads → ~80 MB file
        let file = bigSeekFile(payloadBytes: payload)
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        // Bias the undershoot to ~one cluster so the cold landing sync scans at most
        // ~one payload to find the bracketing cluster header.
        let hit = sampler.keyframeBoundary(near: 12.4, info: info,
                                           marginBytes: Int64(payload + 50_000))
        XCTAssertEqual(hit?.startSeconds ?? -1, 12.0, accuracy: 1e-9)
        // Bounded by ~one cluster (cold sync) + header probes — far below the file
        // size, and independent of how many large clusters precede the target.
        XCTAssertLessThan(sampler.stats.bytesRead, payload * 2)
        XCTAssertLessThan(sampler.stats.bytesRead, file.count / 4)
    }

    /// The per-seek cost must NOT grow with seek depth: resolving a keyframe deep in
    /// the timeline reads about the same as one near the start (the byte-fraction
    /// estimate jumps straight there — no walk from the file head). This is the
    /// property that makes on-demand far-seek cheap on a 40 GB / 2.5 h title.
    func testKeyframeBoundary_costIndependentOfSeekDepth() {
        let payload = 1_000_000
        let file = bigSeekFile(payloadBytes: payload)
        let near = MatroskaKeyframeSampler(source: MemorySource(file))
        let far = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let i1 = near.parseInit(), let i2 = far.parseInit() else { return XCTFail("init") }
        let margin = Int64(payload + 50_000)
        XCTAssertEqual(near.keyframeBoundary(near: 2.4, info: i1, marginBytes: margin)?.startSeconds ?? -1,
                       2.0, accuracy: 1e-9)
        XCTAssertEqual(far.keyframeBoundary(near: 17.4, info: i2, marginBytes: margin)?.startSeconds ?? -1,
                       17.0, accuracy: 1e-9)
        // Deep seek reads within 2× of the shallow seek — bounded, not O(depth).
        XCTAssertLessThan(far.stats.bytesRead, near.stats.bytesRead * 2 + 200_000)
    }

    // MARK: - discoverKeyframeAtOrAfter contract (B7's open-time cadence probe)

    func testAtOrAfter_returnsFirstKeyframeAtOrAfter() {
        let file = bigSeekFile() // keyframes at 0,1,…,19s
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        let m: Int64 = 250_000
        // Exactly on a boundary → that keyframe.
        XCTAssertEqual(sampler.keyframeSeconds(atOrAfter: 5.0, info: info, marginBytes: m) ?? -1, 5.0, accuracy: 1e-9)
        // Between boundaries → the NEXT keyframe (at/after semantics, vs at/before).
        XCTAssertEqual(sampler.keyframeSeconds(atOrAfter: 5.4, info: info, marginBytes: m) ?? -1, 6.0, accuracy: 1e-9)
        XCTAssertEqual(sampler.keyframeSeconds(atOrAfter: 12.01, info: info, marginBytes: m) ?? -1, 13.0, accuracy: 1e-9)
        // Before the first keyframe → the first keyframe.
        XCTAssertEqual(sampler.keyframeSeconds(atOrAfter: 0.0, info: info, marginBytes: m) ?? -1, 0.0, accuracy: 1e-9)
    }

    /// B7's GOP-cadence estimate walks the first ~8 keyframes at open. From t≈0 the
    /// estimate lands at the file head and forward-steps header-only — a handful of
    /// KB total, NOT B6's ~1 MiB/keyframe av_read_frame payload reads.
    func testAtOrAfter_cadenceWalk_isCheap() {
        let payload = 1_000_000 // 1 MB clusters → reads must stay far below one payload
        let file = bigSeekFile(payloadBytes: payload)
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        // Walk the first 8 keyframes the way an open-time cadence estimate would.
        var t = -0.0001
        var seen: [Double] = []
        for _ in 0..<8 {
            guard let k = sampler.discoverKeyframeAtOrAfter(t + 0.0001) else { break }
            seen.append(k)
            t = k
        }
        XCTAssertEqual(seen, [0,1,2,3,4,5,6,7].map(Double.init))
        // Whole 8-keyframe cadence walk reads less than ONE 1 MB cluster payload:
        // proves it size-skips structurally instead of reading frame data.
        XCTAssertLessThan(sampler.stats.bytesRead, payload)
    }

    /// Cursor-safety / statelessness: repeated calls are pure — same answer every
    /// time, and the only mutation is the byte counter. There is no shared demux
    /// cursor for the contract to disturb (it reads via positioned ranged GETs).
    func testAtOrAfter_isPureAndRepeatable() {
        let file = bigSeekFile()
        let sampler = MatroskaKeyframeSampler(source: MemorySource(file))
        let a = sampler.discoverKeyframeAtOrAfter(9.3)
        let b = sampler.discoverKeyframeAtOrAfter(9.3)
        let c = sampler.discoverKeyframeAtOrAfter(9.3)
        XCTAssertEqual(a ?? -1, 10.0, accuracy: 1e-9)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    /// The contract memoizes parseInit: the second call must not re-read the header
    /// region, so a from-head cadence walk's per-call cost stays flat.
    func testAtOrAfter_memoizesInit() {
        let file = bigSeekFile()
        let src = MemorySource(file)
        let sampler = MatroskaKeyframeSampler(source: src)
        _ = sampler.discoverKeyframeAtOrAfter(0.0)
        let afterFirst = src.fetches
        _ = sampler.discoverKeyframeAtOrAfter(0.0)
        let secondCallFetches = src.fetches - afterFirst
        // Second identical call re-walks clusters but must NOT re-parse the header;
        // it issues strictly fewer fetches than the first (which paid init parsing).
        XCTAssertLessThan(secondCallFetches, afterFirst)
    }

    /// Unknown total size (server didn't advertise length) → contract returns nil so
    /// the caller keeps its existing estimate rather than guessing.
    func testAtOrAfter_unknownSizeReturnsNil() {
        final class UnsizedSource: ByteRangeSource {
            let data: [UInt8]
            init(_ d: [UInt8]) { data = d }
            var totalSize: Int64 { -1 }
            func readRange(at offset: Int64, count: Int) -> Data {
                guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
                return Data(data[Int(offset)..<min(data.count, Int(offset) + count)])
            }
        }
        let sampler = MatroskaKeyframeSampler(source: UnsizedSource(bigSeekFile()))
        XCTAssertNil(sampler.discoverKeyframeAtOrAfter(5.0))
    }

    // MARK: - Cues fast-path (PRIMARY track for ~90-95% of library MKVs)

    func testReadCues_trailingCues_exactTableAndOffsets() {
        let times = [0, 6006, 12012, 18018, 24024] // ms ticks @ 1ms scale
        let built = buildFileWithCues(timecodeScale: 1_000_000, durationTicks: 30030,
                                      clusterTimes: times)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        guard let cues = sampler.readCues() else { return XCTFail("readCues nil") }
        // Exact PTS table for the WHOLE timeline — no scan, no estimation.
        XCTAssertEqual(cues.map(\.seconds), built.keyframeSeconds)
        // Absolute cluster offsets resolve correctly and actually land on Cluster IDs.
        let expectedAbs = built.clusterRelOffsets.map { info.segmentDataOffset + Int64($0) }
        XCTAssertEqual(cues.map(\.clusterOffset), expectedAbs)
        for abs in cues.map(\.clusterOffset) {
            let id = Array(built.file[Int(abs)..<Int(abs) + 4])
            XCTAssertEqual(id, [0x1F, 0x43, 0xB6, 0x75], "cue offset must point at a Cluster")
        }
    }

    func testHasCues_trueWithIndex_falseWithout() {
        let withCues = buildFileWithCues(clusterTimes: [0, 1000, 2000])
        XCTAssertTrue(MatroskaKeyframeSampler(source: MemorySource(withCues.file)).hasCues())
        // bigSeekFile / buildFile produce no SeekHead and no Cues.
        let noCues = buildFile(durationTicks: 4000,
                               clusters: [cluster(timecode: 0, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])])
        let s = MatroskaKeyframeSampler(source: MemorySource(noCues))
        XCTAssertFalse(s.hasCues())
        XCTAssertNil(s.readCues())
    }

    /// Non-1ms TimecodeScale must be applied to CueTime exactly (the PTS the muxer
    /// will seek to).
    func testReadCues_appliesTimecodeScale() {
        // 100us ticks: 10 ticks = 1ms; times below are in those ticks.
        let times = [0, 60_060, 120_120]
        let built = buildFileWithCues(timecodeScale: 100_000, durationTicks: 180_180,
                                      clusterTimes: times)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard let cues = sampler.readCues() else { return XCTFail("readCues nil") }
        let oracle = times.map { Double($0) * 100_000.0 / 1e9 }
        XCTAssertEqual(cues.map(\.seconds), oracle)
    }

    /// When a CuePoint indexes multiple tracks, the fast-path must pick the VIDEO
    /// track's cluster position, not an audio track's.
    func testReadCues_filtersToVideoTrack() {
        // Add a bogus audio (track 2) position with a WRONG offset to each CuePoint;
        // the reader must ignore it and use the video (track 1) offset.
        let built = buildFileWithCues(videoTrack: 1, clusterTimes: [0, 6000],
                                      extraPositions: [(track: 2, pos: 999_999)])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard let info = sampler.parseInit() else { return XCTFail("init") }
        guard let cues = sampler.readCues() else { return XCTFail("readCues nil") }
        let expectedAbs = built.clusterRelOffsets.map { info.segmentDataOffset + Int64($0) }
        XCTAssertEqual(cues.map(\.clusterOffset), expectedAbs)
    }

    /// The fast-path is cheap: locating + reading the whole index costs a handful of
    /// small reads (init + SeekHead + Cues body), nowhere near the file size — the
    /// "<1s, ~2 range requests" property R1 measured.
    func testReadCues_isCheap() {
        // 300 keyframes ≈ a 30-min title at 6s GOPs, with ~256KB "frame payloads"
        // per cluster so the file is ~80MB — the fast-path must read ~none of that.
        let times = (0..<300).map { $0 * 6000 }
        let built = buildFileWithCues(durationTicks: 300 * 6000, clusterTimes: times,
                                      payloadBytes: 256 * 1024)
        let src = MemorySource(built.file)
        let sampler = MatroskaKeyframeSampler(source: src)
        guard let cues = sampler.readCues() else { return XCTFail("readCues nil") }
        XCTAssertEqual(cues.count, 300)
        // Whole index located + read in well under 100 KB and a handful of fetches —
        // bounded by the INDEX size, NOT the ~80 MB of frame payload (file-size /
        // bitrate independent). This is the "<1s, ~2 range requests" property.
        XCTAssertLessThan(sampler.stats.bytesRead, 100_000)
        XCTAssertLessThan(src.fetches, 40)
        XCTAssertGreaterThan(built.file.count, 40_000_000)
    }

    // MARK: - Cues plan source (trustworthiness gate)

    /// A dense, well-formed Cues index is TRUSTWORTHY: the plan source returns the
    /// exact full-timeline table B7 publishes as an exact-EXTINF VOD.
    func testKeyframePlanFromCues_dense_isTrustworthy() {
        let times = [0, 6006, 12012, 18018, 24024] // ~6s GOPs @ 1ms scale
        let built = buildFileWithCues(durationTicks: 30030, clusterTimes: times)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard case let .trustworthy(points, maxGap) = sampler.keyframePlanFromCues() else {
            return XCTFail("expected trustworthy")
        }
        XCTAssertEqual(points.map(\.seconds), built.keyframeSeconds)
        XCTAssertEqual(maxGap, 6.006, accuracy: 1e-6) // largest consecutive spacing
    }

    /// A single-keyframe Cues index is NOT trustworthy (can't anchor EXTINF spacing):
    /// the gate signals tooFewPoints so the caller uses its uniform-4s fallback.
    func testKeyframePlanFromCues_tooFewPoints_untrustworthy() {
        let built = buildFileWithCues(durationTicks: 4000, clusterTimes: [0])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard case let .untrustworthy(reason) = sampler.keyframePlanFromCues() else {
            return XCTFail("expected untrustworthy")
        }
        XCTAssertEqual(reason, .tooFewPoints(count: 1))
    }

    /// A Cues index with a consecutive-keyframe gap beyond the 30s threshold is
    /// sparse/clustered and NOT trustworthy — publishing it would diverge from the
    /// real cuts and stall AVPlayer, so the gate rejects it.
    func testKeyframePlanFromCues_largeGap_untrustworthy() {
        // 0 → 6s → 50s: the 44s middle gap exceeds the 30s trust threshold.
        let times = [0, 6000, 50000]
        let built = buildFileWithCues(durationTicks: 56000, clusterTimes: times)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard case let .untrustworthy(reason) = sampler.keyframePlanFromCues() else {
            return XCTFail("expected untrustworthy")
        }
        XCTAssertEqual(reason, .gapTooLarge(maxGapSeconds: 44.0))
    }

    /// The threshold is configurable: the same large-gap index becomes trustworthy
    /// when the caller raises maxGapSeconds above the observed gap.
    func testKeyframePlanFromCues_thresholdConfigurable() {
        let times = [0, 6000, 50000] // 44s max gap
        let built = buildFileWithCues(durationTicks: 56000, clusterTimes: times)
        let sampler = MatroskaKeyframeSampler(source: MemorySource(built.file))
        guard case .trustworthy = sampler.keyframePlanFromCues(maxGapSeconds: 45.0) else {
            return XCTFail("expected trustworthy at raised threshold")
        }
    }

    /// No Cues element at all → .absent, so the caller uses the walker / uniform
    /// fallback (NEVER a client-side timeline scan).
    func testKeyframePlanFromCues_noCues_absent() {
        let noCues = buildFile(durationTicks: 4000,
                               clusters: [cluster(timecode: 0, blocks: [simpleBlock(track: 1, rel: 0, keyframe: true)])])
        let sampler = MatroskaKeyframeSampler(source: MemorySource(noCues))
        XCTAssertEqual(sampler.keyframePlanFromCues(), .absent)
    }

    /// The gate is BOUNDED like readCues: deciding trustworthiness on a large (~80MB)
    /// file still reads only the index, never the frame payloads.
    func testKeyframePlanFromCues_isCheapOnLargeFile() {
        let times = (0..<300).map { $0 * 6000 }
        let built = buildFileWithCues(durationTicks: 300 * 6000, clusterTimes: times,
                                      payloadBytes: 256 * 1024)
        let src = MemorySource(built.file)
        let sampler = MatroskaKeyframeSampler(source: src)
        guard case let .trustworthy(points, _) = sampler.keyframePlanFromCues() else {
            return XCTFail("expected trustworthy")
        }
        XCTAssertEqual(points.count, 300)
        XCTAssertLessThan(sampler.stats.bytesRead, 100_000)
        XCTAssertLessThan(src.fetches, 40)
    }
}
#endif
