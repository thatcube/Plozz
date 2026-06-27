#if canImport(SwiftUI)
import CoreModels
import FeaturePlayback
#if canImport(UIKit)
import EngineMPV
#endif

/// The single composition switch for Plozz's dual-engine playback.
///
/// `AppShell` is the only module that links the heavy on-device decode engines,
/// so it owns the one decision of which hybrid engine is wired in and whether the
/// hybrid feature is available at all. Flipping `enabled` turns **both** halves of
/// the feature off together — the engine routing/fallback *and* the capability
/// advertising — which keeps the "advertise ⇔ route" invariant intact: a format is
/// only advertised as direct-play when there's a real engine wired in to play it.
///
///   * ``enabled`` gates the provider capability expansion (the extra MKV / DTS /
///     TrueHD direct-play formats the servers will then send raw).
///   * ``engineFactory()`` injects the hybrid `VideoEngine` constructor into every
///     `PlayerViewModel`, which routes to it per the resolved source.
///
/// The hybrid engine is **mpv** (libmpv + libplacebo): it processes Dolby Vision
/// RPU (so Profile 5/8 render correctly, not green) and outputs HDR10/HLG.
///
/// When no UIKit engine is linked (e.g. a macOS unit-test build), everything
/// collapses to the native-only path, so behaviour is byte-for-byte today's.
enum HybridPlayback {
    /// Which on-device engine backs hybrid playback when one is linked. mpv is
    /// the only engine today; VLCKit (the former alternative) is archived at the
    /// `archive/vlckit-engine` git tag and can be restored from there if ever
    /// needed. The enum is kept so a future engine can be added behind the same
    /// composition switch.
    enum Engine { case mpv }

    /// The hybrid engine to use.
    static let preferredEngine: Engine = .mpv

    /// Whether this build links an engine for AVPlayer-incompatible media.
    static var enabled: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// The engine factory injected into `PlayerViewModel`. Supplies the hybrid
    /// engine when linked; otherwise the native-only default.
    @MainActor
    static func engineFactory() -> EngineFactory {
        #if canImport(UIKit)
        switch preferredEngine {
        case .mpv:
            return EngineFactory(makeHybrid: { _ in MPVVideoEngineFactory.makeEngine() })
        }
        #else
        return .native
        #endif
    }

    /// Registers the FFmpeg-backed local-remux engines into the shared
    /// `LocalRemuxStrategyRegistry`. Only `AppShell` links these engines, so it
    /// contributes them at launch; on a non-UIKit (unit-test) build this is a no-op
    /// and only the harness's reference strategy exists.
    @MainActor
    static func registerLocalRemuxEngines() {
        #if canImport(UIKit)
        CueDrivenLocalRemuxEngine.register()
        #endif
    }
}
#endif
