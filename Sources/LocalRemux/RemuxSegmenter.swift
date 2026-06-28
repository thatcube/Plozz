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

    /// B7: progressive lazy/windowed index is active for this source (the flag was
    /// on AND the source has no usable keyframe index, so it was switched into
    /// lazy mode). When false the segment table is final at open (index-built, or
    /// the legacy fixed-cadence / keyframe-scan tables).
    let lazyEnabled: Bool

    /// B7: full-VOD provisional-timeline mode is active (the remuxFullVod flag was on
    /// AND the source has no usable keyframe index). The full 0->duration table is
    /// published for instant full-timeline seek; the C core forward-snaps each
    /// segment's boundaries on mux. False for index-built/no-op sources.
    let fullVodEnabled: Bool

    /// B7 per-phase read-ahead (bytes) for the shared range reader, switched inside
    /// the demuxer `lock` so seek-heavy keyframe PROBING never inherits the large
    /// segment-MUXING read-ahead (which would over-fetch megabytes past each probed
    /// keyframe). `muxReadAhead` tracks the boosted muxing granularity.
    ///
    /// Sized at 64KB to make B6's cheap cluster-header probe actually cheap: a header
    /// parse issues a single ~16KB direct `read_raw_at` (count < read-ahead), so a
    /// 64KB floor caps each header probe at one 64KB fetch instead of a 1 MiB refill
    /// (~16x fewer bytes/probe on the background fill). The av_read_frame fallback /
    /// calibration path is NOT hurt: libavformat refills its 1 MiB avio buffer with
    /// large `count` reads, which dominate the 64KB floor, so those stay full-size.
    private let probeReadAhead = 1 << 16
    private var muxReadAhead = 1 << 20

    /// Progress of one `extendLazyIndex` batch.
    struct LazyProgress: Sendable, Equatable {
        /// Number of fully-bracketed segments now published (monotonic).
        var ready: Int
        /// Whether discovery reached EOF — the timeline is now the complete VOD set.
        var complete: Bool
        /// Seek-probes spent this batch (the open-latency / discovery-cost metric).
        var probes: Int
    }

    /// Opens `sourceURL` and builds the segment table. Throws a `RemuxOpenError`
    /// carrying the precise failing libavformat stage + AVERROR + network reason
    /// when the file can't be demuxed, so the caller's fallback path can report
    /// exactly why (vs an opaque failure).
    init(sourceURL: URL, headers: [String: String] = [:], targetSegmentSeconds: Double = 6.0,
         deriveEac3FrameDur: Bool = false, keyframeScan: Bool = false,
         keyframeLazy: Bool = false, fullVod: Bool = false) throws {
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

        // B7 lazy/windowed index (com.plozz.playback.remuxLazyIndex). When the source
        // has no usable keyframe index, switch the C core into PROGRESSIVE discovery:
        // probe only the first window now (instant launch), then let a background
        // driver extend the frontier. Takes precedence over the upfront keyframeScan
        // when both are set (it solves the same correctness problem without paying
        // O(total-segments) synchronously at open). A no-op for index-built sources.
        var lazyEngaged = false
        if keyframeLazy, !fullVod, plozz_remux_uses_fixed_cadence(session) == 1 {
            let openStart = DispatchTime.now().uptimeNanoseconds
            let netBefore = reader.networkSnapshot()
            // Enable B6's cheap cluster-header keyframe probe BEFORE lazy_begin (it
            // snapshots the mode into the per-session probe context). Each boundary's
            // PTS then comes from a ~16KB header read instead of av_read_frame'ing the
            // whole ~1.4MB IDR — the dominant open-latency/scrub byte cost. Self-
            // calibrates and falls back to av_read_frame on any mismatch.
            plozz_remux_set_keyframe_index_mode(session, 1)
            if plozz_remux_lazy_begin(session) == 1 {
                lazyEngaged = true
                // Probe just enough to publish the first couple of segments so
                // AVPlayer can start immediately; the rest fills in the background.
                // Small per-call batches (not one big 24-probe call) so we STOP the
                // instant ready>=2, keeping the open footprint a handful of probes —
                // and HARD-CAPPED independent of total runtime (the 2.5h/40GB title
                // must open as cheaply as a 20min one; B6 crashed scanning the whole
                // timeline here). The remainder is discovered in the background.
                reader.setReadAhead(probeReadAhead)
                let openProbeBatch: Int32 = 2   // probes per call (re-check ready often)
                let openProbeMaxLoops = 24      // hard cap: <= 48 probes at open, ever
                var ready: Int32 = 0
                var complete: Int32 = 0
                var totalProbes = 0
                var guardLoops = 0
                repeat {
                    var p: Int32 = 0
                    _ = plozz_remux_lazy_extend(session, 0, openProbeBatch, &ready, &complete, &p)
                    totalProbes += Int(p)
                    guardLoops += 1
                    if p == 0 { break }   // no forward progress (e.g. seek failure) — bail
                } while ready < 2 && complete == 0 && guardLoops < openProbeMaxLoops
                let openMs = Double(DispatchTime.now().uptimeNanoseconds &- openStart) / 1_000_000
                // Bytes-read at open is the head-to-head score vs B6's upfront scan
                // (which reads ~11% / 584 MB before first frame). The windowed index
                // only resolves the first segments now, so this is the <<1% number the
                // coordinator greps to compare time-to-first-frame footprint.
                let after = reader.networkSnapshot()
                let openBytes = max(0, after.bytesFetched - netBefore.bytesFetched)
                let openFetches = after.fetchCount - netBefore.fetchCount
                let total = reader.totalSize
                let pct = total > 0 ? Double(openBytes) / Double(total) * 100.0 : 0.0
                RemuxLog.info(String(format:
                    "remux-lazy: open window ready=%d complete=%d probes=%d open-latency=%.0fms open-bytes=%.2fMB(%.3f%%) fetches=%d",
                    ready, complete, totalProbes, openMs,
                    Double(openBytes) / 1_048_576.0, pct, openFetches))
            } else {
                RemuxLog.info("RemuxSegmenter: lazy-index begin declined; keeping table")
            }
        }
        self.lazyEnabled = lazyEngaged

        // Flag-gated (com.plozz.playback.remuxKeyframeScan): when the open-time table
        // is the FIXED-CADENCE fallback (source has no usable keyframe index), rebuild
        // it on the file's REAL keyframe boundaries — discovered via cheap BACKWARD
        // seek-probes — so each segment's EXTINF equals the muxed span and consecutive
        // segments don't overlap (the fix for the progressive desync/stutter on
        // no-index titles). Must run BEFORE reading the segment count below, since it
        // can change segment_count. A no-op for index-built tables, when OFF, and when
        // the B7 lazy index already engaged (mutually exclusive — same correctness).
        if keyframeScan && !lazyEngaged && !fullVod {
            // Bracket the rebuild with the reader's byte/fetch counters so the cost of
            // seek-sampled discovery is visible in the log: it must be O(segments) tiny
            // ranged reads, NOT O(filesize) — the open-latency advantage over a full
            // av_read_frame-to-EOF keyframe scan that stalls on multi-GB 4K titles.
            let before = reader.networkSnapshot()
            let total = reader.size()
            plozz_remux_set_keyframe_scan(session, 1)
            let after = reader.networkSnapshot()
            let scanBytes = after.bytesFetched - before.bytesFetched
            let scanFetches = after.fetchCount - before.fetchCount
            let pct = total > 0 ? Double(scanBytes) / Double(total) * 100 : 0
            RemuxLog.info(String(format:
                "RemuxSegmenter: keyframe-scan discovery read %lld bytes (%.1f%% of %lld) in %d fetches",
                scanBytes, pct, total, scanFetches))
        }

        // B7 full-VOD provisional timeline (com.plozz.playback.remuxFullVod). Publishes
        // the full 0->duration fixed-cadence table so the ENTIRE scrub bar is seekable
        // at open (instant launch AND full-timeline seek — the requirement the windowed
        // lazy EVENT playlist failed), while muxing each segment with forward-snapped
        // contiguous boundaries so adjacent segments never overlap/duplicate (anti-
        // desync). Takes precedence over lazy/keyframeScan (both skipped above) and is a
        // byte-identical no-op for index-built (Cues/DoVi) sources. Must run BEFORE the
        // duration read below since it can change the cadence/segment count.
        var fullVodEngaged = false
        if fullVod, plozz_remux_uses_fixed_cadence(session) == 1 {
            let openStart = DispatchTime.now().uptimeNanoseconds
            let netBefore = reader.networkSnapshot()
            if plozz_remux_set_full_vod_mode(session, 1) == 1 {
                fullVodEngaged = true
                let openMs = Double(DispatchTime.now().uptimeNanoseconds &- openStart) / 1_000_000
                let after = reader.networkSnapshot()
                let openBytes = max(0, after.bytesFetched - netBefore.bytesFetched)
                let openFetches = after.fetchCount - netBefore.fetchCount
                let total = reader.totalSize
                let pct = total > 0 ? Double(openBytes) / Double(total) * 100.0 : 0.0
                let segs = Int(plozz_remux_segment_count(session))
                // ZERO upfront keyframe discovery: open cost is just avformat_open +
                // table publish, independent of runtime/filesize. This is the headline
                // TTFF number — the whole timeline is seekable with no scan tax.
                RemuxLog.info(String(format:
                    "remux-fullvod: open segs=%d open-latency=%.0fms open-bytes=%.2fMB(%.3f%%) fetches=%d",
                    segs, openMs, Double(openBytes) / 1_048_576.0, pct, openFetches))
            } else {
                RemuxLog.info("RemuxSegmenter: full-vod declined (indexed source); serving as-is")
            }
        }
        self.fullVodEnabled = fullVodEngaged

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

    /// B7: advance progressive keyframe discovery by one bounded batch (serialised
    /// with `mediaSegment` on the same lock, since both drive the single-threaded
    /// demuxer). `untilSeconds <= 0` means "toward EOF"; `maxProbes` caps the
    /// backward-seek probes this call so the lock is released promptly between
    /// batches and on-demand muxing can interleave. Returns the current ready
    /// segment count, completion, and probes spent. No-op (ready = published count,
    /// complete = true) when lazy mode isn't active.
    func extendLazyIndex(untilSeconds: Double, maxProbes: Int) -> LazyProgress {
        lock.lock()
        defer { lock.unlock() }
        guard let session, lazyEnabled else {
            return LazyProgress(ready: session.map { Int(plozz_remux_segment_count($0)) } ?? 0,
                                complete: true, probes: 0)
        }
        var ready: Int32 = 0
        var complete: Int32 = 0
        var probes: Int32 = 0
        // Seek-heavy discovery: cap read-ahead so each probe pulls only what it needs
        // to reach the next keyframe PTS, never the boosted muxing read-ahead.
        reader.setReadAhead(probeReadAhead)
        _ = plozz_remux_lazy_extend(session, untilSeconds, Int32(maxProbes),
                                    &ready, &complete, &probes)
        return LazyProgress(ready: Int(ready), complete: complete == 1, probes: Int(probes))
    }

    /// B7: the current published segment durations (snapshot under the demuxer
    /// lock). Grows as background discovery extends the frontier; in non-lazy mode
    /// this is just the final table.
    func currentSegmentDurations() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return [] }
        let count = Int(plozz_remux_segment_count(session))
        var durations: [Double] = []
        durations.reserveCapacity(count)
        for i in 0..<count {
            var seg = plozz_remux_segment()
            if plozz_remux_segment_at(session, Int32(i), &seg) == 1 {
                durations.append(seg.duration_seconds)
            }
        }
        return durations
    }

    /// B7: the current published segment count (cheap, under the lock).
    func currentSegmentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return 0 }
        return Int(plozz_remux_segment_count(session))
    }

    /// B7: discovery boundaries resolved by the cheap cluster-header parse so far
    /// (vs the av_read_frame fallback). Confirms the cheap probe engaged.
    func lazyHeaderReads() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return 0 }
        return Int(plozz_remux_lazy_header_reads(session))
    }

    /// Raise the range reader's per-round-trip read-ahead (one-time, before the
    /// origin serves) so high-bitrate 4K segments fetch in fewer round-trips.
    func boostReadAhead(_ bytes: Int) {
        muxReadAhead = max(muxReadAhead, bytes)
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
        // Segment muxing wants the large read-ahead for throughput; restore it here
        // in case a lazy probe batch left the small probe cap in place (both run
        // under this lock, so the switch is race-free).
        if lazyEnabled { reader.setReadAhead(muxReadAhead) }
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
