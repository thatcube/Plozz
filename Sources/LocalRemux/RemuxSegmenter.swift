import Foundation
import CRemuxCore

// MARK: - C callback adapters (non-capturing → C function pointers)

private func remuxReadAdapter(_ opaque: UnsafeMutableRawPointer?,
                              _ buf: UnsafeMutablePointer<UInt8>?,
                              _ size: Int32) -> Int32 {
    guard let opaque, let buf, size > 0 else { return -1 }
    let reader = Unmanaged<HTTPRangeReader>.fromOpaque(opaque).takeUnretainedValue()
    return Int32(reader.read(into: buf, count: Int(size)))
}

private func remuxSeekAdapter(_ opaque: UnsafeMutableRawPointer?,
                              _ offset: Int64,
                              _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    let reader = Unmanaged<HTTPRangeReader>.fromOpaque(opaque).takeUnretainedValue()
    if whence == PLOZZ_REMUX_SEEK_SIZE { return reader.size() }
    return reader.seek(offset: offset, whence: whence)
}

private func remuxLogAdapter(_ opaque: UnsafeMutableRawPointer?,
                             _ level: Int32,
                             _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message)
    switch level {
    case 2: RemuxLog.error(text)
    case 1: RemuxLog.info(text)
    default: RemuxLog.debug(text)
    }
}

/// Installs the C-side log bridge exactly once for the process.
private let installRemuxLogBridge: Void = {
    plozz_remux_set_log(remuxLogAdapter, nil)
}()

// MARK: - RemuxSegmenter

/// A precise reason `plozz_remux_open` couldn't prepare the source. Surfaced as a
/// thrown error (instead of an opaque "demux failed") so a cold device play's
/// captured `String(describing: error)` immediately reveals *which* step failed
/// and *why* — e.g. `local remux open failed at avformat_open_input (HTTP 401)`
/// pinpoints a stale token, vs `... (AVERROR -1414092869)` an unsupported probe.
struct RemuxOpenError: Error, CustomStringConvertible, Equatable {
    /// libavformat stage that failed (`plozz_remux_stage` raw value).
    let stage: Int
    /// AVERROR from the failing libavformat call (0 when not applicable).
    let averror: Int32
    /// Network-level reason captured by the reader (HTTP status / transport
    /// error), when the failure was an I/O read rather than a parse.
    let httpReason: String?

    var description: String {
        RemuxOpenError.describe(stage: stage, averror: averror, httpReason: httpReason)
    }

    /// Human label for a `plozz_remux_stage` value.
    static func stageLabel(_ stage: Int) -> String {
        switch stage {
        case Int(PLOZZ_REMUX_STAGE_ALLOC.rawValue): return "alloc"
        case Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue): return "avformat_open_input"
        case Int(PLOZZ_REMUX_STAGE_FIND_STREAM_INFO.rawValue): return "avformat_find_stream_info"
        case Int(PLOZZ_REMUX_STAGE_NO_VIDEO.rawValue): return "no video stream"
        case Int(PLOZZ_REMUX_STAGE_EMPTY_SEGMENTS.rawValue): return "empty segment table"
        default: return "unknown(\(stage))"
        }
    }

    /// Pure, unit-testable formatter for the thrown reason. Prefers the network
    /// reason (the real root cause when the bytes never arrived) and falls back
    /// to the AVERROR for parse/format failures.
    static func describe(stage: Int, averror: Int32, httpReason: String?) -> String {
        var detail = "local remux open failed at \(stageLabel(stage))"
        if let httpReason, !httpReason.isEmpty {
            detail += " (\(httpReason))"
        } else if averror != 0 {
            detail += " (AVERROR \(averror))"
        }
        return detail
    }
}

/// Swift wrapper over `CRemuxCore`: opens the original MKV (lazily, via an
/// `HTTPRangeReader`), exposes the keyframe-aligned segment table, and vends the
/// shared fMP4 init segment plus each `-c copy` media segment on demand.
///
/// All `plozz_remux_*` calls block on the calling thread while ranged reads
/// happen, so callers must invoke this off the main thread (the origin server
/// runs it on its own queue).
final class RemuxSegmenter: @unchecked Sendable {

    /// Probe facts captured at open, used to gate (P7 rejection) and to build the
    /// playlists.
    struct Facts: Sendable {
        var width: Int
        var height: Int
        var frameRate: Double
        var durationSeconds: Double
        var videoCodec: String
        var videoTag: String
        var audioCodec: String
        var audioChannels: Int
        var hasDolbyVision: Bool
        var dolbyVisionProfile: Int
        var dolbyVisionLevel: Int
        var dolbyVisionELPresent: Bool
        var segmentDurations: [Double]

        var audioIsEAC3: Bool { audioCodec.lowercased() == "eac3" }
        /// Single-layer Dolby Vision suitable for AVPlayer (Profile 5 or 8, no
        /// enhancement layer). Profile 7 dual-layer is explicitly excluded.
        var isSingleLayerDoVi: Bool {
            hasDolbyVision && !dolbyVisionELPresent
                && (dolbyVisionProfile == 5 || dolbyVisionProfile == 8)
        }
    }

    private let reader: HTTPRangeReader
    private var session: OpaquePointer?
    private let lock = NSLock()
    let facts: Facts

    /// Opens `sourceURL` and builds the segment table. Throws a `RemuxOpenError`
    /// carrying the precise failing libavformat stage + AVERROR + network reason
    /// when the file can't be demuxed, so the caller's fallback path can report
    /// exactly why (vs an opaque failure).
    init(sourceURL: URL, headers: [String: String] = [:], targetSegmentSeconds: Double = 6.0,
         deriveEac3FrameDur: Bool = false, keyframeScan: Bool = false,
         keyframeIndex: Bool = false, parallelScan: Bool = false,
         parallelConcurrency: Int = 8) throws {
        _ = installRemuxLogBridge
        let reader = HTTPRangeReader(url: sourceURL, headers: headers)
        self.reader = reader

        var result = plozz_remux_open_result()
        let opaque = Unmanaged.passUnretained(reader).toOpaque()
        guard let session = plozz_remux_open(opaque, remuxReadAdapter, remuxSeekAdapter,
                                             targetSegmentSeconds, &result),
              result.ok == 1 else {
            let error = RemuxOpenError(
                stage: Int(result.error_stage),
                averror: result.error_code,
                httpReason: reader.lastFailure
            )
            RemuxLog.error("RemuxSegmenter: \(error.description) for \(sourceURL.lastPathComponent)")
            throw error
        }
        self.session = session
        // Flag-gated (com.plozz.playback.remuxEac3FrameDur): use the bitstream-probed
        // E-AC-3 frame sample count instead of the fixed 1536 fallback. The probe
        // already ran inside open(); this only selects whether the muxer consumes it.
        plozz_remux_set_derive_eac3_frame_dur(session, deriveEac3FrameDur ? 1 : 0)

        // Flag-gated (com.plozz.playback.remuxKeyframeScan): when the open-time table
        // is the FIXED-CADENCE fallback (source has no usable keyframe index), rebuild
        // it on the file's REAL keyframe boundaries — discovered via cheap BACKWARD
        // seek-probes — so each segment's EXTINF equals the muxed span and consecutive
        // segments don't overlap (the fix for the progressive desync/stutter on
        // no-index titles). Must run BEFORE reading the segment count below, since it
        // can change segment_count. A no-op for index-built tables and when OFF.
        if keyframeScan {
            // Flag-gated (com.plozz.playback.remuxParallelScan): collapse the in-process
            // scan's serialized seek-probe RTTs by discovering K disjoint timeline slices
            // CONCURRENTLY, each on its own probe session + byte reader, then applying the
            // merged real-keyframe boundaries to this session. Only attempted when the
            // open-time table is the fixed-cadence fallback (no usable index), so index
            // titles never pay the K probe-opens — they stay byte-identical. Falls back to
            // the in-process sequential scan when discovery yields nothing.
            var appliedParallel = false
            if parallelScan, plozz_remux_used_fixed_cadence(session) == 1 {
                let total = reader.size()
                if let pr = ParallelKeyframeDiscovery.discover(
                        sourceURL: sourceURL, headers: headers,
                        durationSeconds: result.duration_seconds,
                        targetSeconds: targetSegmentSeconds,
                        concurrency: parallelConcurrency, keyframeIndex: keyframeIndex) {
                    let applied = pr.keyframes.withUnsafeBufferPointer { buf in
                        Int(plozz_remux_apply_keyframes(session, buf.baseAddress, Int32(buf.count)))
                    }
                    if applied > 0 {
                        appliedParallel = true
                        let pct = total > 0 ? Double(pr.bytesRead) / Double(total) * 100 : 0
                        RemuxLog.info(String(format:
                            "RemuxSegmenter: PARALLEL keyframe-scan rebuilt %d segments from %d keyframes "
                            + "across %d slices (%d complete) — read %lld bytes (%.1f%% of %lld) in %d fetches, "
                            + "%.2fs wall [index=%@]",
                            applied, pr.keyframes.count, pr.sliceCount, pr.completeSlices,
                            pr.bytesRead, pct, total, pr.fetchCount, pr.elapsedSeconds,
                            keyframeIndex ? "on" : "off"))
                    }
                }
                if !appliedParallel {
                    RemuxLog.info("RemuxSegmenter: parallel keyframe-scan produced no table — falling back to sequential scan")
                }
            }

            // Flag-gated (com.plozz.playback.remuxKeyframeIndex): cut discovery's
            // per-probe byte cost by reading each boundary keyframe's PTS from the
            // Matroska cluster HEADER (a few KB) instead of demuxing the whole keyframe
            // packet (~one 4K IDR ≈ 1+ MiB). Shrink the reader's read-ahead so the
            // direct header reads don't over-fetch, then restore it for muxing. The C
            // side self-validates against av_read_frame and falls back on any mismatch.
            if !appliedParallel {
                let restoreReadAhead = reader.currentReadAhead
                if keyframeIndex {
                    plozz_remux_set_keyframe_index_mode(session, 1)
                    reader.setReadAhead(64 * 1024)
                }
                // Bracket the rebuild with the reader's byte/fetch counters so the cost of
                // seek-sampled discovery is visible in the log: it must be O(segments) tiny
                // ranged reads, NOT O(filesize) — the open-latency advantage over a full
                // av_read_frame-to-EOF keyframe scan that stalls on multi-GB 4K titles.
                let before = reader.networkSnapshot()
                let total = reader.size()
                plozz_remux_set_keyframe_scan(session, 1)
                let after = reader.networkSnapshot()
                if keyframeIndex { reader.setReadAhead(restoreReadAhead) }
                let scanBytes = after.bytesFetched - before.bytesFetched
                let scanFetches = after.fetchCount - before.fetchCount
                let pct = total > 0 ? Double(scanBytes) / Double(total) * 100 : 0
                RemuxLog.info(String(format:
                    "RemuxSegmenter: keyframe-scan discovery read %lld bytes (%.1f%% of %lld) in %d fetches [index=%@]",
                    scanBytes, pct, total, scanFetches, keyframeIndex ? "on" : "off"))
            }
        }

        var durations: [Double] = []
        let count = Int(plozz_remux_segment_count(session))
        durations.reserveCapacity(count)
        for i in 0..<count {
            var seg = plozz_remux_segment()
            if plozz_remux_segment_at(session, Int32(i), &seg) == 1 {
                durations.append(seg.duration_seconds)
            }
        }

        self.facts = Facts(
            width: Int(result.width),
            height: Int(result.height),
            frameRate: result.frame_rate,
            durationSeconds: result.duration_seconds,
            videoCodec: Self.cString(&result.video_codec.0),
            videoTag: Self.cString(&result.video_tag.0),
            audioCodec: Self.cString(&result.audio_codec.0),
            audioChannels: Int(result.audio_channels),
            hasDolbyVision: result.has_dovi_config == 1,
            dolbyVisionProfile: Int(result.dovi_profile),
            dolbyVisionLevel: Int(result.dovi_level),
            dolbyVisionELPresent: result.dovi_el_present == 1,
            segmentDurations: durations
        )
        RemuxLog.info("RemuxSegmenter: opened \(facts.width)x\(facts.height)@\(String(format: "%.3f", facts.frameRate)) \(facts.videoCodec)/\(facts.audioCodec) "
            + "DoVi p\(facts.dolbyVisionProfile) L\(facts.dolbyVisionLevel) EL=\(facts.dolbyVisionELPresent) segs=\(durations.count)")
    }

    /// The shared fMP4 init segment (ftyp + moov).
    func initSegment() -> Data? {
        guard let data = generate({ session, out, len in plozz_remux_init_segment(session, out, len) }) else {
            RemuxLog.error("RemuxSegmenter: init.mp4 generation FAILED")
            return nil
        }
        // Box-scan the init so the pullable file log proves the local mux carried
        // the Dolby Vision config (dvcC/dvvC) + E-AC-3 (dec3) — the make-or-break
        // metadata — without needing a separate box-scan tool on the device.
        RemuxLog.info("RemuxSegmenter: init.mp4 \(data.count) bytes — \(Self.scanInit(data))")
        return data
    }

    /// The media segment at `index` (moof + mdat), remuxed from the nearest
    /// preceding source keyframe.
    func mediaSegment(_ index: Int) -> Data? {
        guard let data = generate({ session, out, len in plozz_remux_media_segment(session, Int32(index), out, len) }) else {
            RemuxLog.error("RemuxSegmenter: seg\(index) generation FAILED")
            return nil
        }
        return data
    }

    /// Cumulative network throughput counters from the underlying range reader,
    /// for the per-segment throughput-starvation diagnostic.
    func networkSnapshot() -> HTTPRangeReader.NetworkSnapshot {
        reader.networkSnapshot()
    }

    /// Raise the range reader's per-round-trip read-ahead (one-time, before the
    /// origin serves) so high-bitrate 4K segments fetch in fewer round-trips.
    func boostReadAhead(_ bytes: Int) {
        reader.boostReadAhead(bytes)
    }

    /// Scans an fMP4 init segment for the box four-cc atoms that matter for the
    /// DoVi+Atmos make-or-break, returning a compact summary for the log.
    private static func scanInit(_ data: Data) -> String {
        let scan = boxScan(data)
        let dovi = scan.hasDoViConfig ? "DoVi-cfg=YES" : "DoVi-cfg=NO"
        let atmos = scan.hasDec3 ? "dec3=YES" : "dec3=NO"
        return "boxes=[\(scan.found.joined(separator: ","))] \(dovi) \(atmos)"
    }

    /// The result of scanning an fMP4 (init) segment for the four-cc atoms that
    /// decide whether Dolby Vision renders and Atmos survives.
    struct BoxScan: Equatable, Sendable {
        /// Markers present, in canonical order.
        var found: [String]
        /// A Dolby Vision configuration box (`dvcC` or `dvvC`) is present — the
        /// make-or-break for Profile 5 (no HDR10 fallback → black screen without it).
        var hasDoViConfig: Bool
        /// The Dolby Vision HEVC sample entry (`dvh1`) is present — required; a
        /// plain `hev1`/`hvc1` entry would drop the DoVi signalling → black screen.
        var hasDVH1: Bool
        /// An E-AC-3 `dec3` config box is present — proves Atmos/JOC passed through
        /// the `-c copy` mux untouched.
        var hasDec3: Bool
    }

    /// Pure box-scan over an fMP4 byte buffer. Exposed (not private) so the
    /// make-or-break metadata detection — DoVi sample entry `dvh1`, DoVi config
    /// `dvcC`/`dvvC`, E-AC-3 `dec3` — is unit-testable with synthetic bytes,
    /// independent of a live FFmpeg mux.
    static func boxScan(_ data: Data) -> BoxScan {
        func has(_ s: String) -> Bool {
            guard let needle = s.data(using: .ascii) else { return false }
            return data.range(of: needle) != nil
        }
        let markers = ["ftyp", "moov", "mvex", "trak", "hvc1", "hev1", "dvh1", "dvhe",
                       "hvcC", "dvcC", "dvvC", "mp4a", "ec-3", "dec3", "ac-3", "dac3"]
        return BoxScan(
            found: markers.filter(has),
            hasDoViConfig: has("dvcC") || has("dvvC"),
            hasDVH1: has("dvh1"),
            hasDec3: has("dec3")
        )
    }

    private func generate(_ body: (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int32>) -> Int32) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var len: Int32 = 0
        guard body(session, &out, &len) == 1, let out, len > 0 else { return nil }
        let data = Data(bytes: out, count: Int(len))
        plozz_remux_free_buffer(out)
        return data
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            plozz_remux_close(session)
            self.session = nil
        }
    }

    deinit { close() }

    private static func cString(_ ptr: UnsafeMutablePointer<CChar>) -> String {
        String(cString: ptr)
    }
}

// MARK: - Parallel keyframe discovery

/// Bounded-parallel keyframe discovery for the full-at-open keyframe scan
/// (`com.plozz.playback.remuxParallelScan`, default OFF).
///
/// The in-process scan is wall-clock-bound by N serialized `avformat_seek_file`
/// BACKWARD probes on a single libav cursor — at feature length that is seconds of
/// RTT even with the cheap 64 KB cluster-header probe (which cut BYTES, not the
/// serialized round-trips). This splits the timeline into K disjoint slices and
/// discovers each slice's real keyframe boundaries CONCURRENTLY, each on its own
/// probe session + `HTTPRangeReader` (separate URLSession connection + demux cursor),
/// using the same self-calibrating `plozz_remux_kf_probe_next` primitive. That
/// collapses the serialized RTTs to ~N/K, so a multi-GB / 2.5 h no-Cues title can
/// rebuild its WHOLE timeline near the couple-second bar.
///
/// Crucially the merged boundaries are all real keyframes and `apply_keyframes` stamps
/// each EXTINF as the true span, so the table stays on the VOD+ENDLIST playlist —
/// native full-timeline seek is preserved (the differentiator vs a windowed EVENT
/// design). And it is IN SYNC BY CONSTRUCTION even if a slice is capped early: a region
/// with few sampled keyframes just yields a longer in-sync segment, never the
/// EXTINF-vs-span mismatch that causes the progressive desync.
enum ParallelKeyframeDiscovery {

    /// Telemetry + the merged keyframe list returned to the caller.
    struct Result {
        var keyframes: [Double]   // merged, sorted, 0-based, keyframes[0] == 0
        var sliceCount: Int
        var completeSlices: Int   // slices that reached their end before the probe cap
        var bytesRead: Int64
        var fetchCount: Int
        var elapsedSeconds: Double
    }

    /// Merge K per-slice keyframe arrays into one sorted, strictly-increasing list with a
    /// t=0 origin. Pure (no I/O) so it is unit-tested directly. `epsilon` collapses the
    /// duplicate boundary keyframe adjacent slices both discover at their shared seam, and
    /// drops any out-of-range sample. Slice order is irrelevant (it sorts globally).
    static func mergeKeyframes(_ slices: [[Double]], duration: Double,
                               epsilon: Double = 0.05) -> [Double] {
        var all: [Double] = [0.0]
        for slice in slices { all.append(contentsOf: slice) }
        all.sort()
        var out: [Double] = []
        out.reserveCapacity(all.count)
        for t in all {
            if t < 0 { continue }
            if duration > 0, t > duration + 0.001 { continue }
            if let last = out.last, t <= last + epsilon { continue }
            out.append(t)
        }
        return out
    }

    /// One slice's discovery outcome, collected under a lock (K is small and each slice
    /// is network-bound, so the lock is negligible and avoids concurrent Array mutation).
    private struct SliceOut {
        var keyframes: [Double]
        var complete: Bool
        var bytes: Int64
        var fetches: Int
    }

    /// Run the parallel discovery over `sourceURL`. Returns nil when it cannot improve on
    /// the in-process scan (no duration, nothing discovered) so the caller falls back to
    /// the sequential `plozz_remux_set_keyframe_scan`.
    static func discover(sourceURL: URL, headers: [String: String],
                         durationSeconds: Double, targetSeconds: Double,
                         concurrency: Int, keyframeIndex: Bool) -> Result? {
        guard durationSeconds > targetSeconds else { return nil }
        let k = max(1, min(concurrency, 32))
        let sliceLen = durationSeconds / Double(k)
        let target = targetSeconds < 1.0 ? 6.0 : targetSeconds

        let lock = NSLock()
        var outs: [SliceOut] = []
        outs.reserveCapacity(k)

        let started = DispatchTime.now()
        DispatchQueue.concurrentPerform(iterations: k) { i in
            let sliceStart = Double(i) * sliceLen
            let sliceEnd = (i == k - 1) ? durationSeconds : Double(i + 1) * sliceLen
            // Generous per-slice probe cap: ~slice/target boundaries, ×3 + slack for
            // sparse keyframes. Bounds a pathological slice without blocking the others;
            // a capped slice degrades to coarser-but-in-sync, never desync.
            let maxProbes = Int((sliceEnd - sliceStart) / target) * 3 + 16

            let reader = HTTPRangeReader(url: sourceURL, headers: headers)
            if keyframeIndex { reader.setReadAhead(64 * 1024) }

            func record(_ keyframes: [Double], complete: Bool) {
                let snap = reader.networkSnapshot()
                lock.lock()
                outs.append(SliceOut(keyframes: keyframes, complete: complete,
                                     bytes: snap.bytesFetched, fetches: snap.fetchCount))
                lock.unlock()
            }

            var result = plozz_remux_open_result()
            let opaque = Unmanaged.passUnretained(reader).toOpaque()
            guard let session = plozz_remux_open(opaque, remuxReadAdapter, remuxSeekAdapter,
                                                 target, &result), result.ok == 1 else {
                record([], complete: false)
                return
            }
            defer { plozz_remux_close(session) }
            if keyframeIndex { plozz_remux_set_keyframe_index_mode(session, 1) }
            guard let probe = plozz_remux_kf_probe_create(session, keyframeIndex ? 1 : 0) else {
                record([], complete: false)
                return
            }
            defer { plozz_remux_kf_probe_free(probe) }

            var found: [Double] = []
            var after = sliceStart
            var probes = 0
            var pts: Double = 0
            while after < sliceEnd && probes < maxProbes {
                probes += 1
                let ok = withUnsafeMutablePointer(to: &pts) {
                    plozz_remux_kf_probe_next(probe, after, target, $0)
                }
                if ok != 1 || pts <= after { break }   // EOF / seek fail / no progress
                found.append(pts)
                after = pts
            }
            // Incomplete only when the probe cap tripped before reaching the slice end;
            // a natural stop (EOF) with room to spare is "complete" for this slice.
            let hitCap = probes >= maxProbes && after < sliceEnd
            record(found, complete: !hitCap)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1e9

        let merged = mergeKeyframes(outs.map { $0.keyframes }, duration: durationSeconds)
        guard merged.count >= 2 else { return nil }
        return Result(keyframes: merged,
                      sliceCount: k,
                      completeSlices: outs.filter { $0.complete }.count,
                      bytesRead: outs.reduce(0) { $0 + $1.bytes },
                      fetchCount: outs.reduce(0) { $0 + $1.fetches },
                      elapsedSeconds: elapsed)
    }
}

