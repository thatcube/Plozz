#if canImport(SwiftUI)
import CoreModels
import FeaturePlayback
#if canImport(UIKit)
import EngineMPV
#endif
#if canImport(VLCKitSPM) && canImport(UIKit)
import EngineVLCKit
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
/// RPU (so Profile 5/8 render correctly, not green) and outputs HDR10/HLG, which
/// VLCKit cannot. VLCKit stays linked purely as a manual escape hatch
/// (``preferredEngine`` = `.vlckit`) in case the mpv Metal/MoltenVK render path
/// misbehaves on a given device — flip the constant and rebuild, no other change.
///
/// When no UIKit engine is linked (e.g. a macOS unit-test build), everything
/// collapses to the native-only path, so behaviour is byte-for-byte today's.
enum HybridPlayback {
    /// Which on-device engine backs hybrid playback when one is linked.
    enum Engine { case mpv, vlckit }

    /// The hybrid engine to use. Currently **VLCKit**: mpv's gpu-next/MoltenVK
    /// render bring-up crashes on device (`mpv_initialize()` re-enters
    /// CoreAnimation/SwiftUI layout while bringing up its Vulkan swapchain on a
    /// not-yet-in-window `CAMetalLayer`), so VLCKit remains the working hybrid
    /// engine until that render path is fixed. Flip back to `.mpv` once the mpv
    /// surface is initialized window-side.
    static let preferredEngine: Engine = .vlckit

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
        case .vlckit:
            #if canImport(VLCKitSPM)
            return EngineFactory(makeHybrid: { VLCKitVideoEngineFactory.makeEngine(captionSettings: $0) })
            #else
            return EngineFactory(makeHybrid: { _ in MPVVideoEngineFactory.makeEngine() })
            #endif
        }
        #else
        return .native
        #endif
    }
}
#endif
