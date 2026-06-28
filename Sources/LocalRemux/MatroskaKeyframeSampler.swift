import Foundation

// MARK: - Byte source

/// Minimal random-access byte source the Matroska sampler pulls from. The live
/// pipeline adapts `HTTPRangeReader` to this; unit tests use an in-memory
/// `Data`-backed source so the EBML byte-shape parsing is exercised without any
/// network or libavformat.
protocol ByteRangeSource: AnyObject {
    /// Total source length in bytes, or -1 if unknown.
    var totalSize: Int64 { get }
    /// Returns up to `count` bytes starting at `offset`. May return fewer near
    /// EOF and an empty `Data` past EOF. Never throws — a failed fetch is empty.
    func readRange(at offset: Int64, count: Int) -> Data
}

// MARK: - EBML primitives (pure, byte-shape unit-tested)

/// Low-level EBML decoders. Matroska is an EBML document: a tree of
/// `[element-ID][data-size][data]` nodes. These are deliberately pure functions
/// over `[UInt8]` + index so the exact byte shapes can be asserted in tests.
enum EBML {

    /// Decodes an EBML **element ID** at `i`. The ID length (1–4 bytes) is given
    /// by the position of the highest set bit in the leading byte. The marker bit
    /// is KEPT — Matroska IDs are canonically written with it (e.g. the Cluster ID
    /// is `0x1F43B675`, a 4-byte ID whose lead byte `0x1F` has its `0x10` bit set).
    /// Returns the ID and the number of bytes it occupied, or nil if truncated.
    static func elementID(_ b: [UInt8], _ i: Int) -> (id: UInt32, len: Int)? {
        guard i >= 0, i < b.count else { return nil }
        let first = b[i]
        let len: Int
        if first & 0x80 != 0 { len = 1 }
        else if first & 0x40 != 0 { len = 2 }
        else if first & 0x20 != 0 { len = 3 }
        else if first & 0x10 != 0 { len = 4 }
        else { return nil } // IDs wider than 4 bytes do not occur in Matroska
        guard i + len <= b.count else { return nil }
        var id: UInt32 = 0
        for k in 0..<len { id = (id << 8) | UInt32(b[i + k]) }
        return (id, len)
    }

    /// Decodes an EBML **variable-length integer** (the encoding used for both
    /// element *data sizes* and in-block track numbers). Unlike an element ID the
    /// marker bit is STRIPPED to yield the value. Returns the value, the byte
    /// length, and whether it is the all-ones "unknown size" sentinel (used by
    /// streamed/live Segments and Clusters whose length wasn't known at mux time).
    static func vint(_ b: [UInt8], _ i: Int) -> (value: UInt64, len: Int, unknown: Bool)? {
        guard i >= 0, i < b.count else { return nil }
        let first = b[i]
        guard first != 0 else { return nil } // length descriptor cannot be in 5th+ byte
        var mask: UInt8 = 0x80
        var len = 1
        while mask != 0 && (first & mask) == 0 { mask >>= 1; len += 1 }
        guard mask != 0, len <= 8, i + len <= b.count else { return nil }
        var value = UInt64(first & (mask &- 1)) // low bits below the marker
        for k in 1..<len { value = (value << 8) | UInt64(b[i + k]) }
        let allOnes = (UInt64(1) << (7 * len)) - 1
        return (value, len, value == allOnes)
    }

    /// Reads a big-endian unsigned integer of `len` bytes (Matroska stores uints,
    /// e.g. Cluster Timecode and TrackNumber, MSB-first with no length prefix).
    static func uint(_ b: [UInt8], _ i: Int, _ len: Int) -> UInt64? {
        guard len >= 1, len <= 8, i >= 0, i + len <= b.count else { return nil }
        var v: UInt64 = 0
        for k in 0..<len { v = (v << 8) | UInt64(b[i + k]) }
        return v
    }

    /// Reads an IEEE-754 float of `len` bytes (4 or 8) — Matroska Duration is a
    /// float scaled by TimecodeScale.
    static func float(_ b: [UInt8], _ i: Int, _ len: Int) -> Double? {
        if len == 4, let bits = uint(b, i, 4) {
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        }
        if len == 8, let bits = uint(b, i, 8) {
            return Double(bitPattern: bits)
        }
        return nil
    }
}

// MARK: - Matroska element IDs

private enum MKV {
    static let ebmlHeader: UInt32   = 0x1A45_DFA3
    static let segment: UInt32      = 0x1853_8067
    static let info: UInt32         = 0x1549_A966
    static let timecodeScale: UInt32 = 0x002A_D7B1
    static let duration: UInt32     = 0x0000_4489
    static let tracks: UInt32       = 0x1654_AE6B
    static let trackEntry: UInt32   = 0x0000_00AE
    static let trackNumber: UInt32  = 0x0000_00D7
    static let trackType: UInt32    = 0x0000_0083
    static let cluster: UInt32      = 0x1F43_B675
    static let timecode: UInt32     = 0x0000_00E7
    static let simpleBlock: UInt32  = 0x0000_00A3
    static let blockGroup: UInt32   = 0x0000_00A0
    static let block: UInt32        = 0x0000_00A1
    static let referenceBlock: UInt32 = 0x0000_00FB

    // SeekHead (the Segment's index of top-level element positions) + Cues (the
    // keyframe index). Used by the Cues fast-path.
    static let seekHead: UInt32     = 0x114D_9B74
    static let seek: UInt32         = 0x0000_4DBB
    static let seekID: UInt32       = 0x0000_53AB
    static let seekPosition: UInt32 = 0x0000_53AC
    static let cues: UInt32         = 0x1C53_BB6B
    static let cuePoint: UInt32     = 0x0000_00BB
    static let cueTime: UInt32      = 0x0000_00B3
    static let cueTrackPositions: UInt32 = 0x0000_00B7
    static let cueTrack: UInt32     = 0x0000_00F7
    static let cueClusterPosition: UInt32 = 0x0000_00F1

    /// The Cues element ID as raw big-endian bytes, for matching a SeekHead entry's
    /// SeekID (which stores the target element's full ID including its marker bit).
    static let cuesIDBytes: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]

    static let videoTrackType: UInt64 = 1
}

// MARK: - Block header

/// The fixed prefix shared by SimpleBlock and Block element *data*: an EBML vint
/// track number, a signed 16-bit big-endian timecode relative to the enclosing
/// cluster, then a flags byte. For SimpleBlock, flags bit `0x80` marks a keyframe.
struct MatroskaBlockHeader {
    var track: UInt64
    var relTimecode: Int16
    var flags: UInt8
    var headerLength: Int
    var isKeyframe: Bool { (flags & 0x80) != 0 }

    /// Parses a block header at `i`. Returns nil if the buffer is too short to
    /// hold the track vint + 3 bytes (rel timecode + flags).
    static func parse(_ b: [UInt8], _ i: Int) -> MatroskaBlockHeader? {
        guard let tn = EBML.vint(b, i) else { return nil }
        let p = i + tn.len
        guard p + 3 <= b.count else { return nil }
        let rel = Int16(bitPattern: (UInt16(b[p]) << 8) | UInt16(b[p + 1]))
        return MatroskaBlockHeader(track: tn.value, relTimecode: rel,
                                   flags: b[p + 2], headerLength: tn.len + 3)
    }
}

// MARK: - Sampler

/// Discovers keyframe-accurate segment boundaries from a Matroska/WebM source by
/// walking only the EBML *structure* — Cluster headers, Timecodes, and block
/// header flags — never the frame payloads. On a library file with known Cluster
/// sizes this is O(cluster-count) tiny ranged reads (a few hundred bytes each):
/// for a 2.5 h 4K title ≈ a megabyte for the whole timeline, versus the hundreds
/// of MB a libavformat `av_read_frame` seek-probe pulls because it must read
/// frame data to land each packet. The output is just `[keyframe seconds]`, so it
/// can feed either a full-at-open table or a lazy/windowed fill.
///
/// This type performs no behavior change on its own; it is an inert primitive
/// until a caller wires it into the discovery path behind a flag.
final class MatroskaKeyframeSampler {

    struct InitInfo: Equatable {
        var videoTrack: UInt64
        var timecodeScale: UInt64   // nanoseconds per timecode tick (default 1_000_000)
        var durationSeconds: Double // 0 if absent
        var segmentDataOffset: Int64
        var firstClusterOffset: Int64
    }

    /// A resumable cursor into the cluster walk so a lazy/windowed caller can
    /// discover `[0, t1]`, return, then resume at exactly the next cluster.
    struct WalkState {
        var clusterOffset: Int64
        var done: Bool
    }

    /// Telemetry for a discovery pass, mirrored to the throughput diagnostic so a
    /// capture can compare bytes-read against the libavformat seek-probe directly.
    struct Stats {
        var bytesRead: Int = 0
        var clustersWalked: Int = 0
        var syncScans: Int = 0
    }

    let source: ByteRangeSource
    /// Bytes pulled per cluster-header probe. A cluster's Timecode + first video
    /// SimpleBlock header live in the first few hundred bytes, so this stays small;
    /// it bounds the per-probe cost even on pathological clusters.
    private let headerProbe: Int
    /// Granularity of the unknown-size sync scan fallback.
    private let scanChunk: Int

    private(set) var stats = Stats()

    /// Memoized `parseInit()` so B7 can call the per-seek contract repeatedly
    /// (e.g. ~8 times to estimate GOP cadence at open) without re-parsing the
    /// header each call. `initComputed` distinguishes "not yet parsed" from
    /// "parsed, not a Matroska source".
    private var initComputed = false
    private var cachedInfo: InitInfo?

    init(source: ByteRangeSource, headerProbe: Int = 4096, scanChunk: Int = 64 * 1024) {
        self.source = source
        self.headerProbe = max(64, headerProbe)
        self.scanChunk = max(4096, scanChunk)
    }

    private func bytes(at offset: Int64, count: Int) -> [UInt8] {
        guard offset >= 0, count > 0 else { return [] }
        let d = source.readRange(at: offset, count: count)
        stats.bytesRead += d.count
        return [UInt8](d)
    }

    // MARK: Init / header

    /// Parses the EBML header, Segment, Info (TimecodeScale, Duration) and Tracks
    /// (first video TrackNumber), and locates the first Cluster. Returns nil if the
    /// source isn't a parseable Matroska Segment.
    func parseInit(maxHeaderBytes: Int = 8 * 1024 * 1024) -> InitInfo? {
        let total = source.totalSize

        // Top-level: an optional EBML header element, then the Segment.
        guard let first = readElementHeader(at: 0) else { return nil }
        let segHeader: ElementHeader?
        if first.id == MKV.ebmlHeader {
            let nextOff = first.dataOffset + max(0, first.dataSize)
            guard let seg = readElementHeader(at: nextOff), seg.id == MKV.segment else { return nil }
            segHeader = seg
        } else if first.id == MKV.segment {
            segHeader = first
        } else {
            segHeader = nil
        }
        guard let seg = segHeader else { return nil }
        return parseSegment(dataOffset: seg.dataOffset, dataSize: seg.dataSize,
                            total: total, maxHeaderBytes: maxHeaderBytes)
    }

    private func parseSegment(dataOffset: Int64, dataSize: Int64, total: Int64,
                              maxHeaderBytes: Int) -> InitInfo? {
        var videoTrack: UInt64?
        var timecodeScale: UInt64 = 1_000_000
        var durationTicks: Double = 0
        var firstCluster: Int64 = -1

        var off = dataOffset
        let segEnd: Int64 = dataSize >= 0 ? dataOffset + dataSize : (total >= 0 ? total : Int64.max)
        let hardStop = dataOffset + Int64(maxHeaderBytes)

        walk: while off < segEnd && off < hardStop {
            guard let el = readElementHeader(at: off) else { break }
            switch el.id {
            case MKV.cluster:
                firstCluster = el.headerOffset
                off = segEnd // first cluster found: header region is done
            case MKV.info:
                let info = bytes(at: el.dataOffset, count: Int(min(Int64(scanChunk), max(0, el.dataSize))))
                parseInfo(info, &timecodeScale, &durationTicks)
                off = el.dataOffset + max(0, el.dataSize)
            case MKV.tracks:
                let trk = bytes(at: el.dataOffset, count: Int(min(Int64(2 * scanChunk), max(0, el.dataSize))))
                videoTrack = parseTracks(trk) ?? videoTrack
                off = el.dataOffset + max(0, el.dataSize)
            default:
                if el.dataSize < 0 { break walk } else { off = el.dataOffset + el.dataSize }
            }
        }

        guard let vt = videoTrack, firstCluster >= 0 else { return nil }
        let durationSeconds = durationTicks > 0 ? durationTicks * Double(timecodeScale) / 1e9 : 0
        return InitInfo(videoTrack: vt, timecodeScale: timecodeScale,
                        durationSeconds: durationSeconds, segmentDataOffset: dataOffset,
                        firstClusterOffset: firstCluster)
    }

    private func parseInfo(_ b: [UInt8], _ scale: inout UInt64, _ durationTicks: inout Double) {
        var i = 0
        while i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            switch el.id {
            case MKV.timecodeScale:
                if let v = EBML.uint(b, el.dataStart, el.dataLen), v > 0 { scale = v }
            case MKV.duration:
                if let v = EBML.float(b, el.dataStart, el.dataLen) { durationTicks = v }
            default: break
            }
            i = el.next
        }
    }

    private func parseTracks(_ b: [UInt8]) -> UInt64? {
        // Find the first TrackEntry whose TrackType == video, return its TrackNumber.
        var i = 0
        while i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.trackEntry {
                if let tn = scanTrackEntry(b, el.dataStart, el.dataStart + el.dataLen) { return tn }
            }
            i = el.next
        }
        return nil
    }

    private func scanTrackEntry(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt64? {
        var number: UInt64?
        var type: UInt64?
        var i = start
        while i < end && i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.trackNumber { number = EBML.uint(b, el.dataStart, el.dataLen) }
            else if el.id == MKV.trackType { type = EBML.uint(b, el.dataStart, el.dataLen) }
            i = el.next
        }
        if type == MKV.videoTrackType { return number }
        return nil
    }

    // MARK: Cluster walk

    /// Walks clusters from `state.clusterOffset` collecting one keyframe time per
    /// cluster until either the next keyframe would exceed `untilSeconds`, the
    /// `byteBudget`/`maxClusters` caps trip, or the source ends. Updates `state`
    /// so the caller can resume exactly where this left off. `untilSeconds == nil`
    /// walks to EOF (bounded by the caps). Boundaries are strictly increasing.
    @discardableResult
    func walkClusters(_ info: InitInfo, state: inout WalkState,
                      untilSeconds: Double?,
                      byteBudget: Int = 32 * 1024 * 1024,
                      maxClusters: Int = 200_000,
                      into out: inout [Double]) -> Bool {
        if state.done { return true }
        let startBytes = stats.bytesRead
        var walked = 0
        let total = source.totalSize

        while state.clusterOffset >= 0 && (total < 0 || state.clusterOffset < total) {
            if walked >= maxClusters { break }
            if stats.bytesRead - startBytes >= byteBudget { break }

            guard let cl = readClusterKeyframe(at: state.clusterOffset, info: info) else {
                state.done = true
                return true
            }
            walked += 1
            stats.clustersWalked += 1

            if let t = cl.keyframeSeconds {
                if let last = out.last { if t > last + 1e-6 { out.append(t) } }
                else { out.append(t) }
                if let limit = untilSeconds, t >= limit {
                    state.clusterOffset = cl.nextClusterOffset
                    if cl.nextClusterOffset < 0 { state.done = true }
                    return state.done
                }
            }

            if cl.nextClusterOffset < 0 || cl.nextClusterOffset <= state.clusterOffset {
                state.done = true
                return true
            }
            state.clusterOffset = cl.nextClusterOffset
        }
        // Ran off the end of the source.
        if total >= 0 && state.clusterOffset >= total { state.done = true }
        return state.done
    }

    /// Convenience: discover every keyframe boundary to EOF (bounded by caps).
    func allKeyframes(_ info: InitInfo, byteBudget: Int = 64 * 1024 * 1024,
                      maxClusters: Int = 200_000) -> [Double] {
        var out: [Double] = []
        var state = WalkState(clusterOffset: info.firstClusterOffset, done: false)
        _ = walkClusters(info, state: &state, untilSeconds: nil,
                         byteBudget: byteBudget, maxClusters: maxClusters, into: &out)
        return out
    }

    /// The per-seek primitive an on-demand VOD origin needs: resolve the real
    /// keyframe-cluster boundary at or just before `targetSeconds` using only
    /// cluster-header reads (a few small ranged GETs, no frame payloads). Returns
    /// the boundary's start time and the byte offset of its Cluster element so the
    /// caller can seek the muxer straight there — making a far-seek snap to a
    /// keyframe in a bounded, file-size-independent read instead of an
    /// av_read_frame scan over the GOP.
    ///
    /// Returns nil if the source isn't byte-seekable (unknown total size / no
    /// duration) or no cluster brackets the target within the bounded search.
    ///
    /// Strategy: estimate the byte offset from `target/duration`, biased to
    /// UNDERSHOOT by `marginBytes` so a short, cheap FORWARD cluster walk lands the
    /// bracketing keyframe — stepping forward skips by the cluster size field,
    /// whereas stepping back would need a fresh sync scan. Sync to the first
    /// cluster at/after the estimate, then walk forward (size-skipping) while the
    /// cluster keyframe time stays <= target; the last such cluster is the answer.
    /// If the estimate overshoots the target with no candidate, back off and retry,
    /// bounded.
    func keyframeBoundary(near targetSeconds: Double, info: InitInfo,
                          marginBytes: Int64 = 8 * 1024 * 1024,
                          maxSteps: Int = 64, maxRetries: Int = 8)
        -> (startSeconds: Double, clusterOffset: Int64)? {
        let total = source.totalSize
        guard total > 0, info.durationSeconds > 0 else { return nil }
        let clamped = max(0, min(targetSeconds, info.durationSeconds))

        var estimate = Int64((clamped / info.durationSeconds) * Double(total)) - marginBytes
        if estimate < info.firstClusterOffset { estimate = info.firstClusterOffset }

        var retries = 0
        while retries <= maxRetries {
            guard let firstOff = clusterAtOrAfter(estimate, info: info) else { return nil }
            var clusterOff = firstOff
            var best: (Double, Int64)? = nil
            var steps = 0
            while steps < maxSteps {
                steps += 1
                guard let cl = readClusterKeyframe(at: clusterOff, info: info),
                      let t = cl.keyframeSeconds else { break }
                if t <= clamped + 1e-6 {
                    best = (t, clusterOff)
                    if cl.nextClusterOffset < 0 || cl.nextClusterOffset <= clusterOff { return best }
                    clusterOff = cl.nextClusterOffset
                } else {
                    // This cluster is already past the target.
                    if let b = best { return b }
                    break // overshot with no candidate → re-seek earlier
                }
            }
            if let b = best { return b }
            if estimate <= info.firstClusterOffset { return nil }
            estimate = max(info.firstClusterOffset, estimate - marginBytes * 2)
            retries += 1
        }
        return nil
    }

    /// A resolved keyframe seek target: the real keyframe presentation time and the
    /// byte offset of the Matroska Cluster that begins it, so a caller can seek
    /// straight to it.
    struct KeyframeHit: Equatable {
        let startSeconds: Double
        let clusterOffset: Int64
    }

    /// Phase-2 façade over `keyframeBoundary(near:)`, named for the lazy
    /// full-duration-VOD engine's on-demand seek call: given a scrub target,
    /// resolve the real keyframe at/just-before it. Pure discovery — it performs
    /// no muxing and mutates no session state, so the engine can call it freely on
    /// any far-seek to learn where the in-sync segment must start. Returns nil only
    /// when the source isn't byte-seekable or no cluster brackets the target.
    func discoverKeyframe(at targetSeconds: Double, info: InitInfo) -> KeyframeHit? {
        keyframeBoundary(near: targetSeconds, info: info).map {
            KeyframeHit(startSeconds: $0.startSeconds, clusterOffset: $0.clusterOffset)
        }
    }

    /// Memoized init parse — see `cachedInfo`. Lets the per-seek contract be called
    /// many times cheaply.
    func cachedInitInfo() -> InitInfo? {
        if !initComputed { cachedInfo = parseInit(); initComputed = true }
        return cachedInfo
    }

    /// The contract B7's open-time GOP-cadence estimator (and any on-demand
    /// far-seek) drops in for B6's `av_read_frame` seek-probe.
    ///
    /// Given a 0-based source time, returns the source PTS in seconds of the first
    /// real keyframe AT OR AFTER `targetSeconds`, or nil when the source isn't a
    /// byte-seekable Matroska (caller should then keep its existing estimate).
    ///
    /// CURSOR-SAFE BY CONSTRUCTION: this performs only positioned, ranged reads
    /// through `ByteRangeSource` at explicit byte offsets. It holds NO libav
    /// `AVFormatContext` and shares NO demux cursor with the muxer, so it cannot
    /// disturb the reader position — there is no sequential file cursor to save or
    /// restore. The only state it mutates is its own `stats` byte counter and the
    /// memoized init. Safe to call before or during playback setup.
    func discoverKeyframeAtOrAfter(_ targetSeconds: Double) -> Double? {
        guard let info = cachedInitInfo() else { return nil }
        return keyframeSeconds(atOrAfter: targetSeconds, info: info)
    }

    /// Forward-walking variant of `keyframeBoundary`: returns the time of the first
    /// keyframe whose PTS is >= `targetSeconds`. Used for cadence estimation (walk
    /// consecutive keyframes from 0) and for snapping a seek up to the next
    /// keyframe. Header-only, payload-free; cost is bounded like the at/before
    /// primitive (one cold sync landing ~one cluster, then size-skip steps).
    func keyframeSeconds(atOrAfter targetSeconds: Double, info: InitInfo,
                         marginBytes: Int64 = 8 * 1024 * 1024,
                         maxSteps: Int = 128, maxRetries: Int = 8) -> Double? {
        let total = source.totalSize
        guard total > 0, info.durationSeconds > 0 else { return nil }
        let clamped = max(0, min(targetSeconds, info.durationSeconds))

        var estimate = Int64((clamped / info.durationSeconds) * Double(total)) - marginBytes
        if estimate < info.firstClusterOffset { estimate = info.firstClusterOffset }

        var retries = 0
        while retries <= maxRetries {
            guard let firstOff = clusterAtOrAfter(estimate, info: info) else { return nil }
            var clusterOff = firstOff
            var steps = 0
            var atHead = clusterOff <= info.firstClusterOffset
            while steps < maxSteps {
                steps += 1
                guard let cl = readClusterKeyframe(at: clusterOff, info: info),
                      let t = cl.keyframeSeconds else { break }
                if t >= clamped - 1e-6 {
                    // First keyframe at/after target. If we LANDED past the target on
                    // our very first read and we're not at the file head, an earlier
                    // keyframe may also satisfy ">= target" — back off to find it.
                    if steps == 1 && !atHead && t > clamped + 1e-6 { break }
                    return t
                }
                atHead = false
                if cl.nextClusterOffset < 0 || cl.nextClusterOffset <= clusterOff { return nil }
                clusterOff = cl.nextClusterOffset
            }
            if estimate <= info.firstClusterOffset { return nil }
            estimate = max(info.firstClusterOffset, estimate - marginBytes * 2)
            retries += 1
        }
        return nil
    }

    /// Offset of the Cluster element at or after `offset`: `offset` itself when it
    /// already sits on a Cluster ID, else a bounded forward sync scan for the next
    /// `0x1F43B675`. Never seeks before the first cluster.
    private func clusterAtOrAfter(_ offset: Int64, info: InitInfo) -> Int64? {
        let start = max(offset, info.firstClusterOffset)
        if let el = readElementHeader(at: start), el.id == MKV.cluster { return start }
        return findClusterSync(from: start)
    }

    private struct ClusterResult {
        var keyframeSeconds: Double?
        var nextClusterOffset: Int64
    }

    /// Reads one cluster's header region: its declared size (to find the next
    /// cluster), Timecode, and the first video keyframe block. Reads only the
    /// header probe window — never the frame payloads.
    private func readClusterKeyframe(at offset: Int64, info: InitInfo) -> ClusterResult? {
        guard let el = readElementHeader(at: offset), el.id == MKV.cluster else {
            // Not at a cluster boundary — fall back to a bounded forward sync scan.
            if let synced = findClusterSync(from: offset) {
                guard let el2 = readElementHeader(at: synced), el2.id == MKV.cluster else { return nil }
                return readClusterBody(el2, info: info)
            }
            return nil
        }
        return readClusterBody(el, info: info)
    }

    private func readClusterBody(_ el: ElementHeader, info: InitInfo) -> ClusterResult {
        // Next cluster: by declared size when known, else a bounded sync scan.
        let nextOffset: Int64
        if el.dataSize >= 0 {
            nextOffset = el.dataOffset + el.dataSize
        } else {
            nextOffset = findClusterSync(from: el.dataOffset) ?? -1
        }

        let probe = bytes(at: el.dataOffset, count: headerProbe)
        var clusterTC: UInt64 = 0
        var keyframeSeconds: Double?

        var i = 0
        while i < probe.count {
            guard let child = readChildHeader(probe, i) else { break }
            if child.id == MKV.timecode {
                clusterTC = EBML.uint(probe, child.dataStart, child.dataLen) ?? 0
            } else if child.id == MKV.simpleBlock {
                if let bh = MatroskaBlockHeader.parse(probe, child.dataStart),
                   bh.track == info.videoTrack, bh.isKeyframe {
                    keyframeSeconds = ticksToSeconds(Int64(clusterTC) + Int64(bh.relTimecode), info)
                    break
                }
            } else if child.id == MKV.blockGroup {
                if let t = firstVideoKeyframeInBlockGroup(probe, child.dataStart,
                                                          child.dataStart + child.dataLen,
                                                          clusterTC: clusterTC, info: info) {
                    keyframeSeconds = t
                    break
                }
            } else if child.id == MKV.cluster {
                break // ran into the next cluster within the probe window
            }
            // Advance past this child. Unknown size inside a cluster header probe
            // shouldn't happen for blocks; guard against a stuck cursor.
            if child.next <= i { break }
            i = child.next
        }

        // mkvmerge starts each video cluster on a keyframe, so when we couldn't
        // confirm a block flag in the probe window we fall back to the cluster
        // Timecode itself as the boundary (still keyframe-accurate for such files).
        if keyframeSeconds == nil && (clusterTC > 0 || el.dataOffset == info.firstClusterOffset) {
            keyframeSeconds = ticksToSeconds(Int64(clusterTC), info)
        }
        return ClusterResult(keyframeSeconds: keyframeSeconds, nextClusterOffset: nextOffset)
    }

    private func firstVideoKeyframeInBlockGroup(_ b: [UInt8], _ start: Int, _ end: Int,
                                               clusterTC: UInt64, info: InitInfo) -> Double? {
        var i = start
        var blockHeader: MatroskaBlockHeader?
        var hasReference = false
        while i < end && i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.block { blockHeader = MatroskaBlockHeader.parse(b, el.dataStart) }
            else if el.id == MKV.referenceBlock { hasReference = true }
            if el.next <= i { break }
            i = el.next
        }
        // A Block with no ReferenceBlock is a keyframe.
        if let bh = blockHeader, bh.track == info.videoTrack, !hasReference {
            return ticksToSeconds(Int64(clusterTC) + Int64(bh.relTimecode), info)
        }
        return nil
    }

    private func ticksToSeconds(_ ticks: Int64, _ info: InitInfo) -> Double {
        Double(ticks) * Double(info.timecodeScale) / 1e9
    }

    /// Bounded forward scan for the Cluster sync `0x1F43B675`, used only when a
    /// cluster's size is the unknown-size sentinel. Capped so a corrupt/streamed
    /// source can never turn this into an unbounded read.
    private func findClusterSync(from offset: Int64, maxScan: Int = 16 * 1024 * 1024) -> Int64? {
        var pos = offset
        var scanned = 0
        let total = source.totalSize
        var carry: [UInt8] = []
        var carryBase: Int64 = offset   // absolute source offset of carry[0]
        // Invariant: pos == carryBase + carry.count, so chunk[j] sits at carryBase + j.
        while scanned < maxScan && (total < 0 || pos < total) {
            stats.syncScans += 1
            let fresh = bytes(at: pos, count: scanChunk)
            if fresh.isEmpty { return nil }
            var chunk = carry
            chunk.append(contentsOf: fresh)
            var k = 0
            while k + 4 <= chunk.count {
                if chunk[k] == 0x1F && chunk[k + 1] == 0x43 && chunk[k + 2] == 0xB6 && chunk[k + 3] == 0x75 {
                    return carryBase + Int64(k)
                }
                k += 1
            }
            if fresh.count < scanChunk { return nil } // reached EOF without a match
            let keep = min(3, chunk.count)            // straddle guard for the 4-byte sync
            carry = Array(chunk.suffix(keep))
            pos += Int64(fresh.count)
            carryBase = pos - Int64(keep)
            scanned += fresh.count
        }
        return nil
    }

    // MARK: - Cues fast-path (the PRIMARY track: ~90-95% of library MKVs)

    /// A keyframe index entry parsed from the Matroska Cues element: the keyframe
    /// presentation time and the absolute byte offset of the Cluster that begins it.
    struct CuePoint: Equatable {
        let seconds: Double
        let clusterOffset: Int64
    }

    /// Cheap presence check: does this source carry a usable Cues keyframe index?
    /// Resolves the Cues element offset (via SeekHead or a bounded top-level scan)
    /// WITHOUT parsing every CuePoint — a couple of small ranged reads. Lets the
    /// open path pick the fast-path vs the walker before committing to either.
    func hasCues() -> Bool {
        guard let info = cachedInitInfo() else { return false }
        return cuesElementOffset(info) != nil
    }

    /// The Cues FAST-PATH. When the source carries a Cues index, parse it into the
    /// EXACT (keyframe PTS, cluster offset) table for the WHOLE timeline in ~2
    /// ranged reads — no cluster scan, no estimation, no fixed cadence. Returns the
    /// points sorted by time (video track only when CueTrack is present), or nil
    /// when there is no usable Cues element (caller then falls back to the walker).
    ///
    /// Cost: one small read to locate Cues (SeekHead is at the Segment front), then
    /// one read of the Cues element body (tens of KB even for a 2.5 h feature: ~one
    /// CuePoint per GOP × ~16 bytes). Independent of file size and bitrate.
    func readCues(maxCuesBytes: Int = 8 * 1024 * 1024) -> [CuePoint]? {
        guard let info = cachedInitInfo() else { return nil }
        guard let cuesOff = cuesElementOffset(info),
              let el = readElementHeader(at: cuesOff), el.id == MKV.cues else { return nil }

        // Read the Cues body (bounded). Unknown-size Cues are rare; cap defensively.
        let size: Int
        if el.dataSize >= 0 { size = Int(min(Int64(maxCuesBytes), el.dataSize)) }
        else { size = maxCuesBytes }
        let body = bytes(at: el.dataOffset, count: size)
        guard !body.isEmpty else { return nil }

        var points: [CuePoint] = []
        var i = 0
        while i < body.count {
            guard let cp = readChildHeader(body, i), cp.id == MKV.cuePoint else {
                guard let any = readChildHeader(body, i) else { break }
                if any.next <= i { break }
                i = any.next
                continue
            }
            if let p = parseCuePoint(body, cp.dataStart, cp.dataStart + cp.dataLen, info: info) {
                points.append(p)
            }
            if cp.next <= i { break }
            i = cp.next
        }
        guard !points.isEmpty else { return nil }
        points.sort { $0.seconds < $1.seconds }
        return points
    }

    /// The verdict of the Cues plan-source: either a TRUSTWORTHY keyframe table the
    /// caller can publish as an exact-EXTINF VOD, or a signal that the caller must
    /// fall back to its uniform-cadence plan (NEVER a client-side timeline scan).
    enum CuesKeyframePlan: Equatable {
        /// Cues present and trustworthy: a sorted, full-timeline (PTS, byteOffset)
        /// table. `maxGapSeconds` is the largest consecutive-keyframe spacing seen
        /// (diagnostic; already within the trust threshold).
        case trustworthy(points: [CuePoint], maxGapSeconds: Double)
        /// Cues present but NOT trustworthy (too few points, or a consecutive-keyframe
        /// gap exceeds the threshold — sparse/clustered index). Use the uniform fallback.
        case untrustworthy(reason: Untrust)
        /// No usable Cues element. Use the walker / uniform fallback.
        case absent

        enum Untrust: Equatable {
            case tooFewPoints(count: Int)
            case gapTooLarge(maxGapSeconds: Double)
        }
    }

    /// The Cues PLAN SOURCE for B7's unified arch: returns a keyframe-accurate plan
    /// directly from the container index, with the AetherEngine trustworthiness gate
    /// applied so a sparse/clustered/absent index degrades to the caller's uniform-4s
    /// fallback rather than a stall.
    ///
    /// GATE (mirrors AetherEngine `keyframeIndexIsTrustworthy`): trust the Cues list
    /// only if `count >= minCount` (default 2) AND the maximum spacing between
    /// CONSECUTIVE keyframes is `<= maxGapSeconds` (default 30s). The leading interval
    /// (0 → first keyframe) is the EXTINF anchor `startPts0`, not gated.
    ///
    /// BOUNDED BY CONSTRUCTION — no linear scan risk: `readCues` reads only the Cues
    /// element body (capped at `maxCuesBytes`, default 8 MiB) via positioned ranged
    /// reads; it never demuxes frames, so a malformed/absent Cues can at worst cost a
    /// single bounded read, not a linear file walk. (That is the structural guarantee
    /// AetherEngine's 10 s `cuePrewarmTimeout` exists to enforce against libav's index
    /// build; here it holds without a wall clock. A caller that still wants a wall-clock
    /// deadline can wrap this call — it is pure and cancellation-safe.)
    ///
    /// CURSOR-SAFE: like all sampler APIs, holds no libav context and shares no demux
    /// cursor; safe to call at open time before the muxer starts.
    func keyframePlanFromCues(minCount: Int = 2,
                              maxGapSeconds: Double = 30.0,
                              maxCuesBytes: Int = 8 * 1024 * 1024) -> CuesKeyframePlan {
        guard let points = readCues(maxCuesBytes: maxCuesBytes) else { return .absent }
        guard points.count >= minCount else {
            return .untrustworthy(reason: .tooFewPoints(count: points.count))
        }
        // points are sorted ascending by readCues; gate the largest consecutive gap.
        var maxGap = 0.0
        var k = 1
        while k < points.count {
            let gap = points[k].seconds - points[k - 1].seconds
            if gap > maxGap { maxGap = gap }
            k += 1
        }
        guard maxGap <= maxGapSeconds else {
            return .untrustworthy(reason: .gapTooLarge(maxGapSeconds: maxGap))
        }
        return .trustworthy(points: points, maxGapSeconds: maxGap)
    }

    /// The full-duration EXACT VOD plan for the Cues fast-path: when the source
    /// carries a TRUSTWORTHY Cues index, groups it into ~`targetSeconds` keyframe-cut
    /// segments and returns the exact `CuesVODPlan` (durations + per-segment byte
    /// offsets) a caller feeds to `RemuxSegmentPlanner.mediaPlaylist()` for a
    /// full-duration VOD + `EXT-X-ENDLIST` (seek-anywhere) with exact `EXTINF`.
    /// Returns nil when the Cues index is absent or untrustworthy — the caller then
    /// falls back to `ProvisionalVODPlan` / uniform cadence (NEVER a client scan).
    /// Total programme length comes from the container `Info/Duration` (cheap, from
    /// the memoized init). Cursor-safe; reads only the index, never frame payloads.
    func cuesVODPlan(targetSeconds: Double = 4.0,
                     minCount: Int = 2,
                     maxGapSeconds: Double = 30.0) -> CuesVODPlan? {
        guard case let .trustworthy(points, _) =
                keyframePlanFromCues(minCount: minCount, maxGapSeconds: maxGapSeconds) else {
            return nil
        }
        let total = cachedInitInfo()?.durationSeconds ?? 0
        return CuesVODPlan(keyframes: points.map { ($0.seconds, $0.clusterOffset) },
                           totalDuration: total, targetSeconds: targetSeconds)
    }

    /// Parses one CuePoint: CueTime (ticks) + the CueTrackPositions for the video
    /// track (or the first one if no track filter matches), yielding the absolute
    /// cluster offset. Returns nil if the CuePoint lacks a time or a cluster pos.
    private func parseCuePoint(_ b: [UInt8], _ start: Int, _ end: Int, info: InitInfo) -> CuePoint? {
        var timeTicks: UInt64?
        var videoOffset: Int64?
        var anyOffset: Int64?
        var i = start
        while i < end && i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.cueTime {
                timeTicks = EBML.uint(b, el.dataStart, el.dataLen)
            } else if el.id == MKV.cueTrackPositions {
                let (track, pos) = parseCueTrackPositions(b, el.dataStart, el.dataStart + el.dataLen)
                if let pos = pos {
                    let abs = info.segmentDataOffset + Int64(bitPattern: pos)
                    if track == info.videoTrack { videoOffset = abs }
                    if anyOffset == nil { anyOffset = abs }
                }
            }
            if el.next <= i { break }
            i = el.next
        }
        guard let t = timeTicks, let off = videoOffset ?? anyOffset else { return nil }
        return CuePoint(seconds: ticksToSeconds(Int64(t), info), clusterOffset: off)
    }

    private func parseCueTrackPositions(_ b: [UInt8], _ start: Int, _ end: Int) -> (track: UInt64?, pos: UInt64?) {
        var track: UInt64?
        var pos: UInt64?
        var i = start
        while i < end && i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.cueTrack { track = EBML.uint(b, el.dataStart, el.dataLen) }
            else if el.id == MKV.cueClusterPosition { pos = EBML.uint(b, el.dataStart, el.dataLen) }
            if el.next <= i { break }
            i = el.next
        }
        return (track, pos)
    }

    /// Resolves the absolute offset of the Cues element: prefer the SeekHead (at the
    /// Segment front) which names Cues' position directly; otherwise a bounded
    /// top-level scan that also catches a Cues element placed before the clusters.
    /// Returns nil if no Cues is found within the header region.
    private func cuesElementOffset(_ info: InitInfo, maxHeaderBytes: Int = 8 * 1024 * 1024) -> Int64? {
        var off = info.segmentDataOffset
        let total = source.totalSize
        let segEnd: Int64 = total >= 0 ? total : Int64.max
        let hardStop = info.segmentDataOffset + Int64(maxHeaderBytes)
        var seekHeadCues: Int64?

        while off < segEnd && off < hardStop {
            guard let el = readElementHeader(at: off) else { break }
            switch el.id {
            case MKV.cues:
                return el.headerOffset
            case MKV.seekHead:
                if let c = parseSeekHeadForCues(el, info: info) { seekHeadCues = c }
                if el.dataSize < 0 { return seekHeadCues }
                off = el.dataOffset + el.dataSize
            case MKV.cluster:
                // Reached media. Cues, if present, is indexed by the SeekHead (it
                // usually trails the clusters); return what the SeekHead told us.
                return seekHeadCues.flatMap { verifyCues(at: $0) }
            default:
                if el.dataSize < 0 { return seekHeadCues.flatMap { verifyCues(at: $0) } }
                off = el.dataOffset + el.dataSize
            }
        }
        return seekHeadCues.flatMap { verifyCues(at: $0) }
    }

    /// Confirms a SeekHead-derived offset actually lands on a Cues element before we
    /// trust it (guards against a stale/relative-base mismatch).
    private func verifyCues(at offset: Int64) -> Int64? {
        guard offset >= 0, let el = readElementHeader(at: offset), el.id == MKV.cues else { return nil }
        return offset
    }

    /// Scans a SeekHead's Seek entries for the one whose SeekID is the Cues ID and
    /// returns the absolute Cues offset (SeekPosition is relative to Segment data).
    private func parseSeekHeadForCues(_ shEl: ElementHeader, info: InitInfo) -> Int64? {
        let size = shEl.dataSize >= 0 ? Int(min(Int64(64 * 1024), shEl.dataSize)) : 64 * 1024
        let body = bytes(at: shEl.dataOffset, count: size)
        guard !body.isEmpty else { return nil }
        var i = 0
        while i < body.count {
            guard let el = readChildHeader(body, i) else { break }
            if el.id == MKV.seek {
                if let pos = seekEntryCuesPosition(body, el.dataStart, el.dataStart + el.dataLen) {
                    return info.segmentDataOffset + Int64(bitPattern: pos)
                }
            }
            if el.next <= i { break }
            i = el.next
        }
        return nil
    }

    /// If a Seek entry targets Cues (SeekID == Cues ID bytes), returns its
    /// SeekPosition; nil otherwise.
    private func seekEntryCuesPosition(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt64? {
        var isCues = false
        var pos: UInt64?
        var i = start
        while i < end && i < b.count {
            guard let el = readChildHeader(b, i) else { break }
            if el.id == MKV.seekID {
                let idBytes = Array(b[el.dataStart..<min(b.count, el.dataStart + max(0, el.dataLen))])
                if idBytes == MKV.cuesIDBytes { isCues = true }
            } else if el.id == MKV.seekPosition {
                pos = EBML.uint(b, el.dataStart, el.dataLen)
            }
            if el.next <= i { break }
            i = el.next
        }
        return isCues ? pos : nil
    }

    // MARK: Element-header reads over the source

    private struct ElementHeader {
        var id: UInt32
        var headerOffset: Int64  // offset of the ID's first byte
        var dataOffset: Int64    // offset of the first data byte
        var dataSize: Int64      // -1 if unknown size
    }

    /// Reads an element header (ID + size) at an absolute source offset.
    private func readElementHeader(at offset: Int64) -> ElementHeader? {
        let b = bytes(at: offset, count: 12) // max 4-byte ID + 8-byte size
        guard let idr = EBML.elementID(b, 0) else { return nil }
        guard let sz = EBML.vint(b, idr.len) else { return nil }
        let headerLen = idr.len + sz.len
        return ElementHeader(id: idr.id, headerOffset: offset,
                             dataOffset: offset + Int64(headerLen),
                             dataSize: sz.unknown ? -1 : Int64(bitPattern: sz.value))
    }

    private struct ChildHeader {
        var id: UInt32
        var dataStart: Int   // index into the buffer of the first data byte
        var dataLen: Int     // data length clamped to the buffer; -1 if unknown
        var next: Int        // index just past this element's data
    }

    /// Decodes an element header from an in-memory buffer (used while scanning a
    /// cluster/info/tracks probe window). `dataLen`/`next` are clamped to the
    /// buffer so a partially-read trailing element can't drive the cursor past the
    /// end of what we actually fetched.
    private func readChildHeader(_ b: [UInt8], _ i: Int) -> ChildHeader? {
        guard let idr = EBML.elementID(b, i) else { return nil }
        guard let sz = EBML.vint(b, i + idr.len) else { return nil }
        let dataStart = i + idr.len + sz.len
        guard dataStart <= b.count else { return nil }
        if sz.unknown {
            return ChildHeader(id: idr.id, dataStart: dataStart, dataLen: -1, next: b.count)
        }
        let want = Int(min(sz.value, UInt64(b.count)))
        let clampedLen = min(want, b.count - dataStart)
        let next = dataStart + clampedLen
        return ChildHeader(id: idr.id, dataStart: dataStart, dataLen: clampedLen, next: next)
    }
}
