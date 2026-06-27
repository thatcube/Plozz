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
        let url = components.baseURL.appendingPathComponent(RemuxRoute.masterName)
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
        guard let segmenter = RemuxSegmenter(sourceURL: source.originalURL) else {
            throw FullTimelineVODError.demuxFailed
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
            throw FullTimelineVODError.demuxFailed
        }

        let planner = RemuxSegmentPlanner(
            segmentDurations: facts.segmentDurations,
            stream: streamInfo(facts: facts, source: source)
        )
        let contentSource = RemuxContentSource(segmenter: segmenter, planner: planner)
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
        let bandwidth = estimatedBandwidth(source: source)
        return RemuxSegmentPlanner.StreamInfo(
            width: width,
            height: height,
            dolbyVisionProfile: profile,
            dolbyVisionLevel: dolbyVisionLevel(width: width, height: height),
            audioIsEAC3: facts.audioIsEAC3,
            bandwidth: bandwidth
        )
    }

    /// A plausible Dolby Vision level for the CODECS token. The init segment's
    /// dvcC/dvvC boxes are what actually drive decode; this just keeps the HLS
    /// CODECS attribute well-formed. Use a UHD-vs-HD split (Dolby level ~6 for 4K,
    /// ~4 below) which AVPlayer accepts for a `dvh1` variant.
    nonisolated static func dolbyVisionLevel(width: Int, height: Int) -> Int {
        let pixels = width * height
        return pixels >= 3840 * 2160 ? 6 : 4
    }

    nonisolated static func estimatedBandwidth(source: LocalRemuxSourceDescriptor) -> Int {
        let video = source.sourceMetadata.video?.bitrate ?? 0
        let audio = source.sourceMetadata.audio?.bitrate ?? 0
        let sum = video + audio
        return sum > 0 ? sum : 0
    }
}

// MARK: - Errors

enum FullTimelineVODError: Error {
    case demuxFailed
    case dualLayerDolbyVision
    case serverUnavailable
}
#endif
