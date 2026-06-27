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
    init(sourceURL: URL, headers: [String: String] = [:], targetSegmentSeconds: Double = 6.0) throws {
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
