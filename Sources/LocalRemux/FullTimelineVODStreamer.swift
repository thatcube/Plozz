#if canImport(AVFoundation)
import Foundation
import CoreModels
import FeaturePlayback

// MARK: - Engine registration

/// Registration entry point for the production full-timeline localhost VOD remux
/// engine. Called once at app launch from AppShell (under `#if canImport(UIKit)`)
/// so `LocalRemuxStrategyRegistry.makeStreamer(for:)` can build it when the
/// (default) `fulltimeline.localhost-vod` strategy is selected for an eligible
/// title. The user-visible choice itself is a CoreModels built-in, so the Remux
/// overlay picker and persistence recognise it even before this runs; this wires
/// the FFmpeg-linked *factory*. Idempotent.
public enum FullTimelineVODEngine {
    public static func register() {
        LocalRemuxStrategyRegistry.register(choice: .fullTimelineVOD) {
            FullTimelineVODStreamer()
        }
    }
}

// MARK: - Streamer

/// The `LocalRemuxStreamer` Plozz routes eligible single-layer Dolby Vision (P5/8)
/// + AC-3 / E-AC-3 MKVs through by default. Each session stands up a loopback HTTP
/// origin serving a full-timeline VOD HLS playlist whose fMP4 segments are `-c
/// copy` remuxed from the original MKV (dvh1 + dvcC/dvvC so DoVi renders, dec3 so
/// E-AC-3 JOC Atmos survives), giving AVPlayer native smooth seeking with no
/// server-side throttling and no seek-ahead 404s.
public struct FullTimelineVODStreamer: LocalRemuxStreamer {
    public let strategy = LocalRemuxStrategyChoice.fullTimelineVOD

    public init() {}

    @MainActor
    public func openSession(source: LocalRemuxSourceDescriptor) async throws -> any LocalRemuxStreamingSession {
        let strategy = self.strategy
        // The probe (libavformat open + stream-info + cue index) does blocking
        // ranged HTTP reads, and starting the listener blocks until ready — do all
        // of it off the main actor, then hand the (Sendable) components to the
        // MainActor session.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try FullTimelineVODSession.buildComponents(source: source)
        }.value
        return FullTimelineVODSession(prepared: prepared, strategy: strategy)
    }
}

// MARK: - Session

@MainActor
public final class FullTimelineVODSession: LocalRemuxStreamingSession {
    public let strategy: LocalRemuxStrategyChoice
    public let metricsController: LocalRemuxMetricsController

    private let components: Components
    private var isTornDown = false

    /// The off-main-actor build product: everything is `Sendable` so it crosses
    /// back to the MainActor session cleanly.
    struct Components: Sendable {
        let segmenter: RemuxSegmenter
        let source: RemuxContentSource
        let server: FullTimelineVODServer
        let baseURL: URL
        let planner: RemuxSegmentPlanner
    }

    init(prepared: Components, strategy: LocalRemuxStrategyChoice) {
        self.components = prepared
        self.strategy = strategy
        self.metricsController = LocalRemuxMetricsController(strategy: strategy)

        // Fold production counters into the shared metrics controller so the
        // diagnostics overlay shows segments produced + bytes pulled live. The
        // callback fires off the main actor; hop back on.
        let controller = metricsController
        prepared.source.onMetrics = { distinctSegments, bytesProduced in
            Task { @MainActor in
                controller.updateStrategyMetrics(
                    segmentCount: distinctSegments,
                    bytesPulled: bytesProduced
                )
            }
        }
        RemuxLog.info("Session: ready, \(prepared.planner.segmentDurations.count) segments, base=\(prepared.baseURL.absoluteString)")
    }

    public func preparePlayback() async throws -> LocalRemuxPreparedStream {
        // Hand AVPlayer the MEDIA playlist directly, NOT the master.
        //
        // On-device root cause of the cold-play `NSURLErrorUnsupportedURL` (-1002):
        // a master's single `#EXT-X-STREAM-INF` advertises `CODECS="dvh1.PP.LL,ec-3"`
        // + `VIDEO-RANGE=PQ`, and tvOS AVPlayer evaluates that variant against the
        // display's *current* capability at load time. While the Apple TV is still
        // mid-handshake into its Dolby Vision HDMI output mode, the only variant
        // momentarily looks unplayable, so AVPlayer rejects the master URL with
        // -1002 *before ever fetching the media playlist* (origin shows master.m3u8
        // fetched, then -1002, media.m3u8 never requested — the exact failure the
        // overlay captured).
        //
        // A media playlist has no STREAM-INF/CODECS/VIDEO-RANGE to gate on, so there
        // is no variant to reject: AVPlayer loads `init.mp4` (whose `dvh1` sample
        // entry + dvcC/dvvC config is what actually lights up Dolby Vision) and the
        // keyframe-cut VOD segments, and plays + seeks natively across the full
        // timeline. This mirrors the proven direct-fMP4 DoVi path. The master route
        // stays served by the origin for diagnostics; we just don't hand it over.
        let url = components.baseURL.appendingPathComponent(RemuxRoute.mediaName)
        return LocalRemuxPreparedStream(
            playbackURL: url,
            isManifestStream: true,
            deliveryMode: .localRemux
        )
    }

    public func teardown() async {
        guard !isTornDown else { return }
        isTornDown = true
        components.source.onMetrics = nil
        components.server.stop()
        components.source.stop()
        components.segmenter.close()
        RemuxLog.info("Session: torn down")
    }

    // MARK: - Off-main build

    /// Builds the reader → segmenter (probe) → planner → content source → loopback
    /// server pipeline. Runs OFF the main actor (blocking I/O). Throws when the
    /// source can't be demuxed, is positively identified as dual-layer Profile 7,
    /// or the origin can't bind — in every case the caller falls back to normal
    /// routing.
    nonisolated static func buildComponents(source: LocalRemuxSourceDescriptor) throws -> Components {
        // Throws a RemuxOpenError carrying the precise failing libavformat stage +
        // AVERROR + HTTP/transport reason, so a cold device play's captured error
        // string pinpoints the cause (e.g. "...avformat_open_input (HTTP 401)").
        //
        // Flag `com.plozz.playback.remuxEac3FrameDur` (DEFAULT OFF): when the muxer
        // has to synthesize a missing (E-)AC-3 frame_size, derive the true syncframe
        // sample count from the bitstream instead of assuming 1536, so a DD+/Atmos
        // stream with non-6-block frames gets an audio duration that matches real
        // time (candidate fix for progressive audio desync). The open-time probe
        // always runs + logs; this flag only selects whether the muxer consumes it.
        let deriveEac3 = UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxEac3FrameDur")
        // Flag `com.plozz.playback.remuxKeyframeScan` (DEFAULT OFF): for sources with
        // no usable keyframe index (the fixed-cadence fallback, which logs "no usable
        // index"), rebuild the segment table on REAL keyframe boundaries discovered by
        // seek-probe so EXTINF == muxed span and segments don't overlap — eliminating
        // the progressive A/V desync + stutter those titles exhibit. No-op otherwise.
        let keyframeScan = UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxKeyframeScan")
        // Flag `com.plozz.playback.remuxLazyIndex` (DEFAULT OFF, B7): for no-index
        // sources, discover real keyframe boundaries PROGRESSIVELY — probe only the
        // first window at open (near-instant launch regardless of file size, incl.
        // 30–40GB), serve a growing EVENT→VOD playlist, and fill the rest in the
        // background off the watchdog path. Solves the same A/V-desync correctness
        // problem as keyframeScan but without the O(total-segments) synchronous
        // open-time cost; takes precedence over keyframeScan when both are set.
        let lazyIndex = UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxLazyIndex")
        // Flag `com.plozz.playback.remuxFullVod` (DEFAULT OFF, B7): for no-index
        // sources, publish the FULL 0->duration provisional table at open so the entire
        // scrub bar is seekable immediately (instant launch AND full-timeline seek —
        // the hard requirement the windowed lazy EVENT playlist could not meet), then
        // forward-snap each segment's boundaries on mux so adjacent segments stay
        // contiguous/non-overlapping (anti-desync). Takes precedence over lazyIndex and
        // keyframeScan; no-op for index-built sources.
        let fullVod = UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxFullVod")
        let segmenter = try RemuxSegmenter(sourceURL: source.originalURL,
                                           deriveEac3FrameDur: deriveEac3,
                                           keyframeScan: keyframeScan,
                                           keyframeLazy: lazyIndex,
                                           fullVod: fullVod)
        if deriveEac3 { RemuxLog.info("Session: remuxEac3FrameDur ON — using probed eac3 frame_size") }
        if keyframeScan { RemuxLog.info("Session: remuxKeyframeScan ON — real-keyframe segment table for no-index sources") }
        if lazyIndex {
            RemuxLog.info("Session: remuxLazyIndex ON — lazy/windowed progressive index"
                + (segmenter.lazyEnabled ? " (engaged: no-index source)" : " (no-op: index-built source)"))
        }
        if fullVod {
            RemuxLog.info("Session: remuxFullVod ON — full-duration provisional VOD + forward-snap mux"
                + (segmenter.fullVodEnabled ? " (engaged: no-index source)" : " (no-op: index-built source)"))
        }
        let facts = segmenter.facts

        // Defense-in-depth gate (the provider eligibility gate already ran): only
        // hard-reject when the probe POSITIVELY identifies a disqualifying case, so
        // we never bounce an eligible title just because libavformat didn't expose
        // a DoVi config record. Dual-layer Profile 7 (enhancement layer present)
        // is the one that must stay on mpv.
        if facts.hasDolbyVision, facts.dolbyVisionELPresent {
            segmenter.close()
            RemuxLog.error("Session: source is dual-layer DoVi (EL present) — refusing, stays on mpv")
            throw FullTimelineVODError.dualLayerDolbyVision
        }
        guard !facts.segmentDurations.isEmpty else {
            segmenter.close()
            throw FullTimelineVODError.emptySegments
        }

        let planner = RemuxSegmentPlanner(
            segmentDurations: facts.segmentDurations,
            stream: streamInfo(facts: facts, source: source)
        )

        // Throughput fix (flag `com.plozz.playback.remuxPrefetch`, DEFAULT OFF):
        // high-bitrate 4K HDR titles starve AVPlayer's audio buffer because each
        // segment is fetched+muxed strictly on demand, serialised behind one lock.
        // When enabled we (a) boost the range reader's per-round-trip read-ahead so
        // a ~10–20 MB segment fetches in a few requests instead of dozens, and
        // (b) background-prefetch the next few segments ahead of the playhead so
        // they are cache-warm before AVPlayer asks. Reading the launch-arg here (it
        // lands in NSArgumentDomain) lets the maintainer A/B exactly this one
        // throughput change on the shared Apple TV. OFF = original on-demand path.
        let prefetchEnabled = UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxPrefetch")
        if prefetchEnabled {
            segmenter.boostReadAhead(4 << 20)
            RemuxLog.info("Session: remuxPrefetch ON — readAhead=4MiB prefetchDepth=3")
        }

        let contentSource = RemuxContentSource(
            segmenter: segmenter,
            planner: planner,
            prefetchDepth: prefetchEnabled ? 3 : 0,
            lazyEnabled: segmenter.lazyEnabled
        )
        // B7: kick off background timeline discovery immediately (off the
        // playback-critical path) so the EVENT playlist grows to a complete VOD
        // list within seconds while AVPlayer already plays the first window.
        if segmenter.lazyEnabled { contentSource.startLazyFill() }
        let server = FullTimelineVODServer { path in contentSource.response(forPath: path) }
        guard let baseURL = server.start() else {
            segmenter.close()
            throw FullTimelineVODError.serverUnavailable
        }
        return Components(
            segmenter: segmenter,
            source: contentSource,
            server: server,
            baseURL: baseURL,
            planner: planner
        )
    }

    /// Maps probe facts + provider metadata onto the playlist `StreamInfo` (CODECS
    /// / RESOLUTION / BANDWIDTH).
    nonisolated static func streamInfo(
        facts: RemuxSegmenter.Facts,
        source: LocalRemuxSourceDescriptor
    ) -> RemuxSegmentPlanner.StreamInfo {
        let profile = facts.dolbyVisionProfile > 0
            ? facts.dolbyVisionProfile
            : (source.normalizedDolbyVisionProfile ?? 5)
        let width = facts.width > 0 ? facts.width : (source.sourceMetadata.video?.width ?? 0)
        let height = facts.height > 0 ? facts.height : (source.sourceMetadata.video?.height ?? 0)
        let frameRate = facts.frameRate > 0 ? facts.frameRate : (source.sourceMetadata.video?.frameRate ?? 0)
        let bandwidth = estimatedBandwidth(source: source)
        return RemuxSegmentPlanner.StreamInfo(
            width: width,
            height: height,
            dolbyVisionProfile: profile,
            dolbyVisionLevel: dolbyVisionLevel(probedLevel: facts.dolbyVisionLevel,
                                               width: width, height: height, frameRate: frameRate),
            audioIsEAC3: facts.audioIsEAC3,
            bandwidth: bandwidth
        )
    }

    /// The Dolby Vision level for the HLS `CODECS` token (`dvh1.PP.LL`). A wrong
    /// level can make AVPlayer refuse the variant, so prefer the value libavformat
    /// read straight from the title's dvcC/dvvC configuration record (authoritative,
    /// and the SAME value movenc copies into the emitted dvcC/dvvC box, so the box
    /// and the manifest can never disagree). Only when the record didn't expose a
    /// level (0/unknown) do we estimate it from the luma sample rate.
    nonisolated static func dolbyVisionLevel(probedLevel: Int, width: Int, height: Int, frameRate: Double) -> Int {
        if probedLevel > 0 { return probedLevel }
        return estimatedDolbyVisionLevel(width: width, height: height, frameRate: frameRate)
    }

    /// Estimates the Dolby Vision level from the luma sample rate (W×H×fps) using
    /// the canonical Dolby tier ladder. Used ONLY as a fallback when no real
    /// `dv_level` is available. The old resolution-only guess (UHD→6 / HD→4) was
    /// wrong for 4K30 (→7), 4K60 (→9) and 1080p30/60 (→4/5); deriving from the
    /// frame rate fixes those. When the frame rate is unknown we keep the coarse
    /// resolution tier so we never compute a bogus low level.
    nonisolated static func estimatedDolbyVisionLevel(width: Int, height: Int, frameRate: Double) -> Int {
        guard width > 0, height > 0 else { return 6 }
        guard frameRate > 0, frameRate.isFinite else {
            return width * height >= 3840 * 2160 ? 6 : 4
        }
        let rate = Double(width * height) * frameRate
        // (max luma sample rate, level) ascending — the canonical Dolby ceilings.
        // Pick the lowest level whose ceiling covers this stream (1% tolerance so
        // 23.976 / 29.97 / 59.94 NTSC rates round to their nominal tier).
        let ladder: [(Double, Int)] = [
            (1280 * 720 * 24, 1),
            (1280 * 720 * 30, 2),
            (1920 * 1080 * 24, 3),
            (1920 * 1080 * 30, 4),
            (1920 * 1080 * 60, 5),
            (3840 * 2160 * 24, 6),
            (3840 * 2160 * 30, 7),
            (3840 * 2160 * 48, 8),
            (3840 * 2160 * 60, 9),
            (3840 * 2160 * 120, 10),
        ]
        for (ceiling, level) in ladder where rate <= ceiling * 1.01 {
            return level
        }
        return ladder.last!.1
    }

    nonisolated static func estimatedBandwidth(source: LocalRemuxSourceDescriptor) -> Int {
        let video = source.sourceMetadata.video?.bitrate ?? 0
        let audio = source.sourceMetadata.audio?.bitrate ?? 0
        let sum = video + audio
        return sum > 0 ? sum : 0
    }
}

// MARK: - Errors

enum FullTimelineVODError: Error, CustomStringConvertible {
    /// The probe opened the source but produced no playable segment table.
    case emptySegments
    /// The source is dual-layer Dolby Vision Profile 7 — must stay on mpv.
    case dualLayerDolbyVision
    /// The loopback origin couldn't bind / become ready.
    case serverUnavailable

    var description: String {
        switch self {
        case .emptySegments:
            return "local remux produced an empty segment table"
        case .dualLayerDolbyVision:
            return "local remux refused dual-layer Dolby Vision (Profile 7) — stays on mpv"
        case .serverUnavailable:
            return "local remux loopback origin could not start"
        }
    }
}
#endif
