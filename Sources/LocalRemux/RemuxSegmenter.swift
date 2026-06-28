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

    /// Target segment length (seconds) captured at open, reused by lazy/windowed
    /// background discovery to keep the same grouping the prefix used.
    private let targetSeconds: Double

    // MARK: Lazy/windowed discovery state (guarded by `lock`)
    /// Accumulated real keyframe times (0-based seconds, ascending, starting at 0)
    /// discovered so far. Grows as background windows complete; re-applied as the
    /// (prefix-stable) segment table.
    private var lazyKf: [Double] = []
    /// True while a background task should keep extending the table.
    private var lazyActive = false
    /// True once discovery reached EOF (or a fixed-cadence tail finished it).
    private var lazyComplete = false
    /// Deferred cache write performed once lazy discovery completes (so resume /
    /// re-watch restores the full index instantly).
    private var lazyPending: PendingCacheStore? = nil

    // MARK: Matroska-sampler lazy state
    /// Set during init when `remuxMatroskaSampler` drives discovery: the standalone
    /// EBML cluster sampler and its parsed init, used by the background window loop
    /// to extend the table by reading only cluster headers (no frame payloads, no
    /// demuxer-cursor contention). `mkvWalk` (the resumable cursor) is guarded by
    /// `lock`; `mkvSampler`/`mkvInfo` are immutable once set.
    private var mkvSampler: MatroskaKeyframeSampler? = nil
    private var mkvInfo: MatroskaKeyframeSampler.InitInfo? = nil
    private var mkvWalk = MatroskaKeyframeSampler.WalkState(clusterOffset: -1, done: false)

    /// Deferred persistent-cache write: set during init when a fresh keyframe scan
    /// rebuilt the table (so it's worth saving), consumed once the rebuilt segment
    /// durations have been read. nil when there's nothing to persist.
    private struct PendingCacheStore {
        let cache: KeyframeIndexCache
        let key: String
        let size: Int64
        let duration: Double
        let target: Double
    }

    /// Opens `sourceURL` and builds the segment table. Throws a `RemuxOpenError`
    /// carrying the precise failing libavformat stage + AVERROR + network reason
    /// when the file can't be demuxed, so the caller's fallback path can report
    /// exactly why (vs an opaque failure).
    /// Set when the segment table was published as a full-duration **provisional
    /// VOD** at open (flag `remuxProvisionalVOD`): the whole timeline is advertised
    /// up front with estimated tail boundaries so AVPlayer permits seek-anywhere
    /// immediately, instead of a growing EVENT list (which clamps far-seek to the
    /// discovered frontier). Read by the streamer to serve a static VOD playlist.
    private(set) var provisionalVODActive = false

    init(sourceURL: URL, headers: [String: String] = [:], targetSegmentSeconds: Double = 6.0,
         deriveEac3FrameDur: Bool = false, keyframeSegments: Bool = false,
         keyframeFullScan: Bool = false, keyframeCache: Bool = false,
         lazyKeyframes: Bool = false, matroskaSampler: Bool = false,
         provisionalVOD: Bool = false) throws {
        _ = installRemuxLogBridge
        let reader = HTTPRangeReader(url: sourceURL, headers: headers)
        self.reader = reader
        self.targetSeconds = targetSegmentSeconds

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

        var pendingStore: PendingCacheStore? = nil

        // Flag-gated (com.plozz.playback.remuxKeyframeSegments): when the source
        // had no usable keyframe index, open() built a fixed-cadence table whose
        // 6 s boundaries don't align to keyframes — long-GOP streams then produce
        // overlapping segments whose real duration differs from the declared
        // EXTINF, desyncing AVPlayer. This rescans real keyframes and rebuilds the
        // table so declared == actual. No-op when the index was already usable.
        if keyframeSegments {
            // The rescan builds the boundary table by sparse seek-sampling
            // (O(segment_count) seeks) by default, falling back to a full
            // sequential scan only if seeking can't cover the stream.
            //
            // CRITICAL: keep the range reader at its DEFAULT read-ahead during this
            // sparse scan. Each boundary seek lands near a keyframe, reads ~one
            // I-frame, then re-seeks to the next target — so a large per-round-trip
            // read-ahead OVER-FETCHES megabytes past each I-frame that we immediately
            // throw away by seeking. At 8 MiB that multiplies the open-time network
            // read (the very cost the user feels as a "brutal" startup on 4K) several
            // times over. The boost IS right for on-demand segment muxing (big
            // sequential 4K segments), so it's restored *after* discovery, below.
            // `keyframeFullScan` (com.plozz.playback.remuxKeyframeFullScan) forces the
            // exhaustive scan as a safety override.

            // Persistent keyframe-index cache (flag com.plozz.playback.remuxKeyframeCache):
            // discovering real keyframe boundaries on a no-Cues source is the
            // expensive open-time cost. It never changes for a given file, so on
            // the FIRST play we scan + persist it, and on every RESUME / re-watch
            // we restore it instantly (no scan, just a tiny sidecar read) — the
            // fast-resume path. Only meaningful when the source actually fell back
            // to fixed-cadence (no usable index); a real-Cues title is already
            // keyframe-aligned and skips all of this.
            let wasFixedCadence = plozz_remux_used_fixed_cadence(session) == 1
            var appliedCache = false
            var lazyStarted = false
            let cache = keyframeCache ? KeyframeIndexCache.makeDefault() : nil
            let sourceSize = (keyframeCache && wasFixedCadence) ? reader.size() : -1
            let sourceDuration = result.duration_seconds
            let cacheKey = (cache != nil && wasFixedCadence)
                ? KeyframeIndexCache.key(url: sourceURL, size: sourceSize, duration: sourceDuration)
                : nil

            if wasFixedCadence, let cache, let cacheKey,
               let boundaries = cache.load(key: cacheKey, expectedSize: sourceSize,
                                           expectedDuration: sourceDuration) {
                boundaries.withUnsafeBufferPointer { buf in
                    _ = plozz_remux_apply_keyframe_boundaries(session, buf.baseAddress,
                                                              Int32(buf.count), targetSegmentSeconds)
                }
                appliedCache = true
            }

            // Flag-gated (com.plozz.playback.remuxMatroskaSampler): drive lazy/
            // windowed discovery with the standalone Matroska EBML keyframe sampler
            // instead of the libavformat seek-probe. The sampler reads ONLY cluster
            // headers + block keyframe flags through its OWN ranged byte source
            // (never frame payloads, never the muxer's demuxer cursor), so the
            // [0,90s] prefix is both instant AND exact, and the background window
            // extension stays genuinely low-byte (a few hundred bytes per cluster)
            // rather than pulling ~one I-frame per boundary. Same prefix-stable
            // EVENT machinery as remuxLazyKeyframes; preferred over it when both are
            // on. Strict no-op for real-Cues titles (wasFixedCadence == false).
            if !appliedCache && !lazyStarted && matroskaSampler && wasFixedCadence {
                let mkvReader = HTTPRangeReader(url: sourceURL, headers: headers)
                let sampler = MatroskaKeyframeSampler(source: HTTPRangeByteSource(mkvReader))
                if let info = sampler.parseInit() {
                    let prefixSeconds = 90.0
                    var walk = MatroskaKeyframeSampler.WalkState(
                        clusterOffset: info.firstClusterOffset, done: false)
                    var kf: [Double] = []
                    _ = sampler.walkClusters(info, state: &walk,
                                             untilSeconds: prefixSeconds, into: &kf)
                    if kf.first != 0.0 { kf.insert(0.0, at: 0) }
                    if kf.count >= 2 {
                        let complete = walk.done
                        kf.withUnsafeBufferPointer { buf in
                            _ = plozz_remux_apply_keyframe_boundaries_ex(session, buf.baseAddress,
                                Int32(buf.count), targetSegmentSeconds, complete ? 1 : 0)
                        }
                        self.lazyKf = kf
                        self.lazyActive = !complete
                        self.lazyComplete = complete
                        self.mkvSampler = sampler
                        self.mkvInfo = info
                        self.mkvWalk = walk
                        lazyStarted = true
                        if let cache, let cacheKey {
                            self.lazyPending = PendingCacheStore(cache: cache, key: cacheKey,
                                size: sourceSize, duration: sourceDuration, target: targetSegmentSeconds)
                        }
                        let fileSize = sourceSize > 0 ? sourceSize : reader.size()
                        let pct = fileSize > 0 ? Double(sampler.stats.bytesRead) / Double(fileSize) * 100 : 0
                        let perCluster = sampler.stats.clustersWalked > 0
                            ? sampler.stats.bytesRead / sampler.stats.clustersWalked : 0
                        RemuxLog.info(String(format:
                            "remux-discovery: matroska sampler read %.3fMB = %.3f%% of %.2fMB "
                                + "(%d clusters, %d syncScans, %dB/cluster, lazy prefix %d keyframes [0,%.0fs])",
                            Double(sampler.stats.bytesRead) / 1_048_576, pct,
                            Double(fileSize) / 1_048_576, sampler.stats.clustersWalked,
                            sampler.stats.syncScans, perCluster, kf.count - 1, prefixSeconds))
                        // Engaged-vs-fallback verdict the capture can read directly:
                        // syncScans counts ONLY clusters whose size was the unknown-size
                        // sentinel (so the next-cluster offset had to be found by a body
                        // scan instead of a size skip). 0 ⇒ all known-size, header-only
                        // cheap; >0 ⇒ that many unknown-size clusters forced body scans.
                        if sampler.stats.syncScans == 0 {
                            RemuxLog.info("remux: matroska cluster sizing — all \(sampler.stats.clustersWalked) prefix clusters KNOWN-SIZE (header-only skip, no body scan)")
                        } else {
                            RemuxLog.info("remux: matroska cluster sizing — \(sampler.stats.syncScans) of \(sampler.stats.clustersWalked) prefix clusters UNKNOWN-SIZE (forced body sync-scan; byte cost inflates here)")
                        }
                        RemuxLog.info("remux: matroska keyframe sampler started — "
                            + "\(complete ? "covered whole source (complete)" : "background extending window-by-window")")
                    } else {
                        // Parsed as Matroska but found no keyframe in the prefix
                        // budget. Keep the crash-proof fixed-cadence table; do NOT
                        // fall through to a timeline scan.
                        lazyStarted = true
                        RemuxLog.info("remux: matroska sampler found no keyframe in [0,90s]; "
                            + "keeping fixed-cadence (no timeline scan)")
                    }
                } else {
                    // Not parseable as Matroska (e.g. a TS/MP4 remux source). Fall
                    // through to the libavformat lazy / bounded rescan paths below.
                    RemuxLog.info("remux: matroska sampler — source not parseable as Matroska; "
                        + "using libavformat discovery")
                }
            }

            // Flag-gated (com.plozz.playback.remuxLazyKeyframes): instead of
            // discovering the WHOLE keyframe table at open (O(filesize) full scan,
            // or even a bounded sparse scan over the entire timeline — both of which
            // still read enough of a 4K / feature-length no-Cues file to make the
            // user wait, or get watchdog-killed), discover only a short PREFIX
            // synchronously so playback starts in a couple seconds, then extend the
            // table window-by-window in the BACKGROUND (see discoverNextWindow). The
            // planner is prefix-stable, so appending later boundaries never changes
            // an already-published segment — safe to serve as an HLS EVENT playlist.
            if !appliedCache && lazyKeyframes && wasFixedCadence && !lazyStarted {
                let prefixSeconds = 90.0
                let netBefore = reader.networkSnapshot()
                let prefix = Self.discoverRange(session, from: 0, to: prefixSeconds,
                                                target: targetSegmentSeconds)
                var kf: [Double] = [0.0]
                kf.append(contentsOf: prefix.kf)
                if kf.count >= 2 {
                    let complete = prefix.reachedEof
                    kf.withUnsafeBufferPointer { buf in
                        _ = plozz_remux_apply_keyframe_boundaries_ex(session, buf.baseAddress,
                            Int32(buf.count), targetSegmentSeconds, complete ? 1 : 0)
                    }
                    self.lazyKf = kf
                    self.lazyActive = !complete
                    self.lazyComplete = complete
                    lazyStarted = true
                    if let cache, let cacheKey {
                        self.lazyPending = PendingCacheStore(cache: cache, key: cacheKey,
                            size: sourceSize, duration: sourceDuration, target: targetSegmentSeconds)
                    }
                    let netAfter = reader.networkSnapshot()
                    let readBytes = max(0, netAfter.bytesFetched - netBefore.bytesFetched)
                    let fileSize = sourceSize > 0 ? sourceSize : reader.size()
                    let pct = fileSize > 0 ? Double(readBytes) / Double(fileSize) * 100 : 0
                    RemuxLog.info(String(format:
                        "remux-discovery: read %.2fMB = %.2f%% of %.2fMB in %d ranged GETs "
                            + "(lazy prefix %d keyframes [0,%.0fs], %d pkts)",
                        Double(readBytes) / 1_048_576, pct, Double(fileSize) / 1_048_576,
                        netAfter.fetchCount - netBefore.fetchCount, kf.count - 1,
                        prefixSeconds, prefix.pkts))
                    RemuxLog.info("remux: lazy keyframe discovery started — "
                        + "\(complete ? "prefix covered whole source (complete)" : "background extending window-by-window")")
                } else {
                    // Prefix found no usable keyframe in the first 90s within the
                    // bounded wall budget. Do NOT fall through to a whole-timeline
                    // scan — at feature length that scan is exactly what watchdog-
                    // kills. Keep the fixed-cadence table built at open: degraded
                    // (may desync) but PLAYABLE and crash-proof. lazyStarted stays
                    // true so the rescan below is skipped entirely.
                    lazyStarted = true
                    RemuxLog.info("remux: lazy keyframe discovery — prefix found no "
                        + "keyframe in [0,90s] within budget; keeping fixed-cadence (no timeline scan)")
                }
            }

            // Flag-gated (com.plozz.playback.remuxProvisionalVOD): convert a partial
            // lazy PREFIX into a FULL-DURATION provisional VOD table at open.
            //
            // On-device we proved the growing EVENT shape (what lazy mode serves) is
            // disqualified: AVPlayer plays it in sync but CLAMPS far-seek to the last
            // advertised segment (a viewer could only skip ~3 min ahead — the
            // discovered frontier). Full-timeline seek is a hard requirement. A VOD
            // list WITH EXT-X-ENDLIST that advertises the WHOLE timeline up front lets
            // AVPlayer permit seek-anywhere immediately. So here we keep the exact,
            // keyframe-cut prefix the sampler just discovered and extend it across the
            // rest of the timeline with an estimated fixed-cadence tail (the prefix's
            // measured GOP cadence), then publish that as a static full table. Seek is
            // immediate everywhere; the estimated-tail segments still mux from their
            // nearest preceding real keyframe, so each is internally clean (the open
            // declared-vs-real seek imprecision on the tail is the cost, traded for
            // full seekability — measured on-device, refined per-segment in a follow-up).
            if provisionalVOD, lazyStarted, lazyActive, !lazyComplete, self.lazyKf.count >= 2 {
                var prefixDurations: [Double] = []
                let pc = Int(plozz_remux_segment_count(session))
                prefixDurations.reserveCapacity(pc)
                for i in 0..<pc {
                    var s = plozz_remux_segment()
                    if plozz_remux_segment_at(session, Int32(i), &s) == 1 {
                        prefixDurations.append(s.duration_seconds)
                    }
                }
                let plan = ProvisionalVODPlan(totalDuration: sourceDuration,
                                              realPrefix: prefixDurations,
                                              targetSeconds: targetSegmentSeconds)
                // Cumulative segment START times, EXCLUDING the final total — add_tail
                // rebuilds the last segment to the real source duration. Boundaries are
                // >= target apart so the C grouping keeps them as-is.
                var boundaries: [Double] = [0]
                var acc = 0.0
                for d in plan.segmentDurations.dropLast() { acc += d; boundaries.append(acc) }
                boundaries.withUnsafeBufferPointer { buf in
                    _ = plozz_remux_apply_keyframe_boundaries_ex(session, buf.baseAddress,
                        Int32(buf.count), targetSegmentSeconds, 1)
                }
                // Serve a STATIC full-duration VOD (no background EVENT growth): the
                // table is complete now, so stop lazy discovery.
                self.lazyActive = false
                self.lazyComplete = true
                self.provisionalVODActive = true
                RemuxLog.info(String(format:
                    "remux: provisional VOD — published FULL timeline %d segments "
                        + "(%d exact prefix + estimated tail @ %.2fs cadence) to %.0fs; "
                        + "ENDLIST at open → seek-anywhere",
                    plan.segmentDurations.count, plan.realPrefixCount, plan.cadence, sourceDuration))
            }

            if !appliedCache && !lazyStarted {
                // Measure exactly how many bytes the keyframe-boundary discovery
                // pulls over the network (and in how many ranged GETs) so the open
                // cost is directly comparable to other approaches (e.g. a full
                // I-frame-read seek-probe) — this is the number that decides whether
                // sparse seeking is actually low-byte on a high-bitrate 4K source.
                let netBefore = reader.networkSnapshot()
                _ = plozz_remux_rescan_keyframe_segments(session, targetSegmentSeconds,
                                                         keyframeFullScan ? 1 : 0)
                if wasFixedCadence {
                    let netAfter = reader.networkSnapshot()
                    let readBytes = max(0, netAfter.bytesFetched - netBefore.bytesFetched)
                    let fileSize = sourceSize > 0 ? sourceSize : reader.size()
                    let pct = fileSize > 0 ? Double(readBytes) / Double(fileSize) * 100 : 0
                    let fetches = netAfter.fetchCount - netBefore.fetchCount
                    RemuxLog.info(String(format:
                        "remux-discovery: read %.2fMB = %.2f%% of %.2fMB in %d ranged GETs "
                            + "(keyframe boundary discovery)",
                        Double(readBytes) / 1_048_576, pct,
                        Double(fileSize) / 1_048_576, fetches))
                }
            }

            // Persist a freshly-rebuilt table for next time: only when we actually
            // scanned (not a cache hit) AND the rescan replaced the fixed-cadence
            // table with a real keyframe one. Derive the boundary list from the
            // rebuilt durations after they're read below.
            if let cache, let cacheKey, !appliedCache, !lazyStarted, wasFixedCadence,
               plozz_remux_used_fixed_cadence(session) == 0 {
                pendingStore = PendingCacheStore(cache: cache, key: cacheKey,
                                                 size: sourceSize, duration: sourceDuration,
                                                 target: targetSegmentSeconds)
            }

            // Discovery is done — now raise the per-round-trip read-ahead so the
            // on-demand fMP4 SEGMENT muxing fetches high-bitrate 4K segments in few
            // large ranged GETs (keeps AVPlayer's buffer fed). boostReadAhead only
            // ever raises the value, so a prior cache-hit path (no scan) gets it too.
            //
            // EXCEPTION: while lazy background discovery is ACTIVE, windows keep
            // sparse-seeking as playback runs, and an 8 MiB read-ahead would make
            // every per-boundary seek over-fetch ~one extra I-frame's worth of bytes
            // we immediately discard. Keep the default read-ahead so background
            // discovery stays low-byte; muxing still fetches sequentially. When lazy
            // is NOT active (cache hit, completed prefix, or prefix-failure fixed-
            // cadence fallback) there is no background seeking, so boost for muxing.
            if !lazyActive {
                reader.boostReadAhead(8 << 20)
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

        // Persist the freshly-discovered keyframe boundaries so a resume / re-watch
        // of this title reopens instantly with the exact table (no scan).
        if let pendingStore {
            let boundaries = KeyframeIndexCache.boundaries(fromDurations: durations)
            pendingStore.cache.store(key: pendingStore.key, size: pendingStore.size,
                                     duration: pendingStore.duration, target: pendingStore.target,
                                     boundaries: boundaries)
            RemuxLog.info("RemuxSegmenter: persisted keyframe-index (\(boundaries.count) boundaries) for fast resume")
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

    // MARK: - Lazy/windowed discovery (background extension)

    /// True while lazy discovery is active and the background loop should keep
    /// extending the table. False in eager / cache-hit / non-lazy modes.
    var isLazyActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return lazyActive && !lazyComplete
    }

    /// Lazy mode only: discover the next window of real keyframes after the current
    /// frontier and grow the segment table. Runs the bounded sparse seek-sample
    /// under the segmenter lock (serialized with segment muxing on the single
    /// demuxer), appends exact keyframe boundaries, re-applies the prefix-stable
    /// table, and returns the grown durations plus whether discovery is now
    /// complete (EOF reached, or a graceful fixed-cadence tail finished a stalled
    /// region). Returns nil when not in lazy mode or already complete.
    func discoverNextWindow(windowSeconds: Double = 30.0) -> (durations: [Double], complete: Bool)? {
        if mkvSampler != nil {
            return discoverNextWindowMatroska(windowSeconds: windowSeconds)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let session, lazyActive, !lazyComplete else { return nil }

        let frontier = lazyKf.last ?? 0.0
        let result = Self.discoverRange(session, from: frontier,
                                        to: frontier + windowSeconds, target: targetSeconds)
        var complete = result.reachedEof
        if result.kf.isEmpty && !complete {
            // Stall: sparse seeking can't advance past the frontier (a degenerate
            // no-Cues region). Rather than spin forever, finish the title with a
            // fixed-cadence tail from the frontier to the source duration. The
            // already-published prefix segments are real keyframes and stay
            // unchanged (prefix-stable); only this tail may slightly overlap —
            // acceptable, and the title remains fully playable to the end.
            let dur = facts.durationSeconds
            var t = frontier + targetSeconds
            while t < dur - 0.001 { lazyKf.append(t); t += targetSeconds }
            complete = true
            RemuxLog.info("remux: lazy discovery stalled at "
                + "\(String(format: "%.1f", frontier))s — fixed-cadence tail to "
                + "\(String(format: "%.1f", dur))s")
        } else {
            lazyKf.append(contentsOf: result.kf)
        }

        lazyKf.withUnsafeBufferPointer { buf in
            _ = plozz_remux_apply_keyframe_boundaries_ex(session, buf.baseAddress,
                Int32(buf.count), targetSeconds, complete ? 1 : 0)
        }
        let durations = finalizeLazyApply(complete: complete, kind: "lazy")
        return (durations, complete)
    }

    /// Matroska-sampler variant of `discoverNextWindow`. Walks the next window of
    /// cluster headers with the sampler's OWN byte source — so the (latency-bound,
    /// low-byte) network I/O runs OUTSIDE the segmenter lock and never contends with
    /// on-demand segment muxing on the shared demuxer. Only the boundary apply +
    /// duration read touch the C session, so those happen under the lock.
    private func discoverNextWindowMatroska(windowSeconds: Double) -> (durations: [Double], complete: Bool)? {
        lock.lock()
        guard session != nil, lazyActive, !lazyComplete,
              let sampler = mkvSampler, let info = mkvInfo else {
            lock.unlock(); return nil
        }
        let frontier = lazyKf.last ?? 0.0
        var walk = mkvWalk
        lock.unlock()

        // I/O outside the lock: independent reader, no demuxer-cursor contention.
        var fresh: [Double] = []
        let bytesBefore = sampler.stats.bytesRead
        let syncBefore = sampler.stats.syncScans
        _ = sampler.walkClusters(info, state: &walk,
                                 untilSeconds: frontier + windowSeconds, into: &fresh)
        let newKf = fresh.filter { $0 > frontier + 1e-6 }
        let windowBytes = sampler.stats.bytesRead - bytesBefore
        let windowSyncs = sampler.stats.syncScans - syncBefore
        RemuxLog.info(String(format:
            "remux-discovery: matroska window [%.0f,+%.0fs] read %.3fMB, %d syncScans, %d keyframes",
            frontier, windowSeconds, Double(windowBytes) / 1_048_576, windowSyncs, newKf.count))

        lock.lock()
        defer { lock.unlock() }
        guard let session, lazyActive, !lazyComplete else { return nil }
        mkvWalk = walk
        var complete = walk.done
        if newKf.isEmpty && !complete {
            // No forward progress this window — finish with a crash-proof fixed-
            // cadence tail (never spin). Published prefix segments stay exact.
            let dur = facts.durationSeconds
            var t = frontier + targetSeconds
            while t < dur - 0.001 { lazyKf.append(t); t += targetSeconds }
            complete = true
            RemuxLog.info("remux: matroska discovery made no progress at "
                + "\(String(format: "%.1f", frontier))s — fixed-cadence tail to "
                + "\(String(format: "%.1f", dur))s")
        } else {
            lazyKf.append(contentsOf: newKf)
        }

        lazyKf.withUnsafeBufferPointer { buf in
            _ = plozz_remux_apply_keyframe_boundaries_ex(session, buf.baseAddress,
                Int32(buf.count), targetSeconds, complete ? 1 : 0)
        }
        let durations = finalizeLazyApply(complete: complete, kind: "matroska")
        return (durations, complete)
    }

    /// Lock MUST be held. Reads the grown segment durations from the C session and,
    /// when discovery is complete, flips the lazy flags, persists the pending cache
    /// (fast resume), and raises the muxing read-ahead. Returns the durations.
    private func finalizeLazyApply(complete: Bool, kind: String) -> [Double] {
        var durations: [Double] = []
        if let session {
            let count = Int(plozz_remux_segment_count(session))
            durations.reserveCapacity(count)
            for i in 0..<count {
                var seg = plozz_remux_segment()
                if plozz_remux_segment_at(session, Int32(i), &seg) == 1 {
                    durations.append(seg.duration_seconds)
                }
            }
        }
        if complete {
            lazyComplete = true
            lazyActive = false
            if let pending = lazyPending {
                let boundaries = KeyframeIndexCache.boundaries(fromDurations: durations)
                pending.cache.store(key: pending.key, size: pending.size,
                                    duration: pending.duration, target: pending.target,
                                    boundaries: boundaries)
                RemuxLog.info("remux: \(kind) discovery complete (\(durations.count) segments) — "
                    + "persisted keyframe-index (\(boundaries.count) boundaries) for fast resume")
                lazyPending = nil
            } else {
                RemuxLog.info("remux: \(kind) discovery complete (\(durations.count) segments)")
            }
            // On-demand 4K segment muxing now benefits from a larger per-round-trip
            // read-ahead (no more sparse seeks to over-fetch). Safe now that no
            // background window will run again.
            reader.boostReadAhead(8 << 20)
        }
        return durations
    }

    /// Calls the C bounded sparse seek-sample over `(from, to]` and marshals the
    /// discovered keyframe times. Static so it can run during init (before `self`
    /// is fully formed) and from `discoverNextWindow` under the lock.
    private static func discoverRange(_ session: OpaquePointer, from: Double, to: Double,
                                      target: Double, maxOut: Int = 512)
        -> (kf: [Double], reachedEof: Bool, pkts: Int) {
        let buf = UnsafeMutablePointer<Double>.allocate(capacity: maxOut)
        defer { buf.deallocate() }
        var outCount: Int32 = 0
        var reachedEof: Int32 = 0
        var pkts: Int = 0
        let rc = plozz_remux_discover_range(session, from, to, target, buf, Int32(maxOut),
                                            &outCount, &reachedEof, &pkts)
        if rc < 0 { return ([], false, pkts) }
        let n = max(0, Int(outCount))
        var kf: [Double] = []
        kf.reserveCapacity(n)
        for i in 0..<n { kf.append(buf[i]) }
        return (kf, reachedEof == 1, pkts)
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
