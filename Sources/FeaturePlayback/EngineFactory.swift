#if canImport(AVFoundation)
import Foundation
import CoreModels

/// Builds the concrete `VideoEngine`s the `PlayerViewModel` routes between.
///
/// This is the seam that keeps `FeaturePlayback` from depending on the heavy
/// on-device decode binaries: `FeaturePlayback` knows only how to make the native
/// (AVPlayer) engine, and the composition root (`AppShell`, which *can* depend on
/// `EnginePlozzigen`) injects a `makePlozzigen` closure that constructs the
/// Plozzigen (AetherEngine) engine. The view model picks a
/// ``CoreModels/PlaybackEngineKind`` via ``CoreModels/EngineRouter`` and calls the
/// matching closure here.
///
/// The default value (``native``) supplies only the native engine, so existing
/// call sites that don't pass a factory keep their byte-for-byte current
/// behaviour (always `NativeVideoEngine`).
public struct EngineFactory {
    /// Builds the AVPlayer-backed engine. Always present.
    public var makeNative: @MainActor (SubtitleStyle) -> any VideoEngine
    /// Builds the Plozzigen engine (FFmpeg demux → HLS-fMP4 → AVPlayer), or `nil`
    /// when the engine isn't linked. This is the sole on-device decode engine:
    /// it plays AVPlayer-incompatible sources (MKV, DoVi/Atmos MKV, HEVC `hev1`,
    /// AV1, DTS/TrueHD, …) and decodes embedded + bitmap (PGS/DVB/DVD) subtitles
    /// itself, so no server transcode/burn-in is needed for them.
    public var makePlozzigen: (@MainActor () -> (any VideoEngine)?)?

    public init(
        makeNative: @escaping @MainActor (SubtitleStyle) -> any VideoEngine = { NativeVideoEngine(style: $0) },
        makePlozzigen: (@MainActor () -> (any VideoEngine)?)? = nil
    ) {
        self.makeNative = makeNative
        self.makePlozzigen = makePlozzigen
    }

    /// Whether the Plozzigen (on-device decode) engine is wired in. Drives the
    /// router's `hybridAvailable` and the cross-engine fallback so advertise ⇔
    /// route stays in lockstep.
    public var plozzigenAvailable: Bool { makePlozzigen != nil }

    /// Native-only factory: the conservative default that preserves today's
    /// behaviour everywhere the Plozzigen engine isn't injected.
    public static let native = EngineFactory()
}
#endif
