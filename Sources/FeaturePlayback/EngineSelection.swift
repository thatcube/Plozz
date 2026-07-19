import CoreModels
import CoreNetworking
import Foundation

/// The pure engine-routing decision extracted from `PlayerViewModel.routeEngine`.
///
/// Given a resolved `PlaybackRequest` and the current engine/subtitle context,
/// it picks which `PlaybackEngineKind` should play it — with *no* engine
/// mutation, network, or actor state — so the decision matrix (networkFile →
/// Plozzigen, local-remux-eligible → Plozzigen, image-subtitle default →
/// Plozzigen, everything else → the router's native/hybrid choice) is directly
/// unit-testable.
///
/// Dual-provider/engine safety: this only *chooses*; the caller still owns
/// engine construction and hand-off. Keeping it pure means Plex and Jellyfin
/// requests route through exactly the same code path.
enum EngineSelection {
    static func route(
        request: PlaybackRequest,
        forceTranscode: Bool,
        plozzigenAvailable: Bool,
        capabilities: MediaCapabilities,
        subtitleRule: SubtitlePolicy.Rule
    ) -> PlaybackEngineKind {
        if request.streamURL?.isFileURL == true, plozzigenAvailable {
            return .plozzigen
        }
        if case .some(.networkFile) = request.playbackSource {
            return .plozzigen
        }

        var kind: PlaybackEngineKind
        if !forceTranscode, plozzigenAvailable,
           let descriptor = request.localRemuxSource,
           case .eligible = descriptor.plozzigenEligibility {
            // Plozzigen handles the full pipeline: FFmpeg demux → HLS-fMP4 →
            // localhost → AVPlayer. Covers HEVC/H.264/VP9/AV1 video with any
            // audio (stream-copy or lossless bridge). The engine reads
            // localRemuxSource.originalSource directly.
            kind = .plozzigen
        } else {
            kind = EngineRouter.selectEngine(
                source: request.sourceMetadata,
                capabilities: capabilities,
                isTranscoding: request.isTranscoding,
                // Plozzigen is the on-device decode engine, so "hybrid available"
                // (needs-on-device-decode is routable) == Plozzigen available.
                // When it isn't wired in, the router stays native.
                hybridAvailable: plozzigenAvailable
            )
            // The router's `.hybrid` return is its abstract "needs on-device
            // decode" signal; Plozzigen (AetherEngine) is that engine. Resolve
            // `.hybrid` to it. (The former backing engine is retired.)
            if kind == .hybrid, plozzigenAvailable {
                kind = .plozzigen
            }
        }

        // If the subtitle that would be shown by default is image-based
        // (PGS/DVB/DVD/VOBSUB), AVPlayer can't render it — route to Plozzigen,
        // which decodes bitmap subtitle packets into image cues that Plozz's
        // overlay draws (no server burn-in). Only when direct-playing and
        // Plozzigen is wired in; a no-op when already routed to Plozzigen.
        if kind == .native, !request.isTranscoding, plozzigenAvailable,
           request.subtitleTracks.defaultSubtitleNeedsHybridEngine(
               mode: subtitleRule.mode,
               preferredLanguage: subtitleRule.preferredLanguage) {
            PlozzLog.playback.info("Default subtitle is image-based; routing to Plozzigen so it can be rendered on-device")
            kind = .plozzigen
        }

        let v = request.sourceMetadata?.video
        HandoffDiagnostics.emit("route kind=\(kind.rawValue) container=\(request.sourceMetadata?.container ?? "-") vcodec=\(v?.codec ?? "-") tag=\(v?.codecTag ?? "-") range=\(v?.videoRange ?? "-") rangeType=\(v?.videoRangeType ?? "-") transfer=\(v?.colorTransfer ?? "-") profile=\(v?.profile ?? "-")")
        return kind
    }
}
