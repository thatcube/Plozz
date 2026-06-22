#if canImport(SwiftUI)
import CoreModels
import FeaturePlayback
#if canImport(VLCKitSPM) && canImport(UIKit)
import EngineVLCKit
#endif

/// The single composition switch for Plozz's dual-engine playback.
///
/// `AppShell` is the only module that links the heavy `EngineVLCKit` binary, so
/// it owns the one decision of whether the hybrid (VLCKit) engine is available.
/// Flipping `enabled` turns **both** halves of the feature off together — the
/// engine routing/fallback *and* the capability advertising — which is what keeps
/// the "advertise ⇔ route" invariant intact: a format is only advertised as
/// direct-play when there's a real engine wired in to play it.
///
///   * ``enabled`` gates the provider capability expansion (the extra MKV / DTS /
///     TrueHD direct-play formats the servers will then send raw).
///   * ``engineFactory()`` injects the `VLCKitVideoEngine` constructor into every
///     `PlayerViewModel`, which routes to it per the resolved source.
///
/// When the VLCKit engine isn't linked (e.g. a macOS unit-test build), both
/// collapse to the native-only path, so behaviour is byte-for-byte today's.
enum HybridPlayback {
    /// Whether this build links an engine for AVPlayer-incompatible media.
    static var enabled: Bool {
        #if canImport(VLCKitSPM) && canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// The engine factory injected into `PlayerViewModel`. Supplies the VLCKit
    /// hybrid engine when linked; otherwise the native-only default.
    @MainActor
    static func engineFactory() -> EngineFactory {
        #if canImport(VLCKitSPM) && canImport(UIKit)
        return EngineFactory(makeHybrid: { VLCKitVideoEngineFactory.makeEngine(captionSettings: $0) })
        #else
        return .native
        #endif
    }
}
#endif
