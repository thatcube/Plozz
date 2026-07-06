#if canImport(SwiftUI)
import CoreModels
import FeaturePlayback
#if canImport(UIKit)
import EnginePlozzigen
#endif

/// The single composition switch for Plozz's playback engines.
///
/// `AppShell` is the only module that links the heavy on-device decode engine
/// (Plozzigen / AetherEngine), so it owns the one decision of whether the
/// on-device decode path is wired in at all. Flipping `enabled` turns **both**
/// halves of the feature off together — the engine routing/fallback *and* the
/// capability advertising — which keeps the "advertise ⇔ route" invariant intact:
/// a format is only advertised as direct-play when there's a real engine wired in
/// to play it.
///
///   * ``enabled`` gates the provider capability expansion (the extra MKV / DTS /
///     TrueHD direct-play formats the servers will then send raw).
///   * ``engineFactory()`` injects the Plozzigen `VideoEngine` constructor into
///     every `PlayerViewModel`, which routes to it per the resolved source.
///
/// Plozzigen (AetherEngine: FFmpeg demux → HLS-fMP4 copy-remux → localhost →
/// AVPlayer) is the sole on-device decode engine. It plays AVPlayer-incompatible
/// media (MKV, DoVi/Atmos MKV, HEVC `hev1`, AV1, DTS/TrueHD, …) and decodes
/// embedded + bitmap (PGS/DVB/DVD) subtitles itself, so nothing needs a server
/// transcode/burn-in. (The former hybrid engine is retired; its archived code is
/// available at historical git tags if ever needed.)
///
/// When no UIKit engine is linked (e.g. a macOS unit-test build), everything
/// collapses to the native-only path, so behaviour is byte-for-byte today's.
enum HybridPlayback {
    /// Whether this build links the on-device decode engine (Plozzigen) for
    /// AVPlayer-incompatible media.
    static var enabled: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// The engine factory injected into `PlayerViewModel`. Supplies the Plozzigen
    /// engine when linked; otherwise the native-only default.
    @MainActor
    static func engineFactory() -> EngineFactory {
        #if canImport(UIKit)
        return EngineFactory(
            makePlozzigen: { PlozzigenVideoEngineFactory.makeEngine() }
        )
        #else
        return .native
        #endif
    }
}
#endif
