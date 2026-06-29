#if canImport(AVFoundation)
import Foundation
import CoreModels

/// Builds the concrete `VideoEngine`s the `PlayerViewModel` routes between.
///
/// This is the seam that keeps `FeaturePlayback` from depending on the heavy
/// VLCKit binary: `FeaturePlayback` knows only how to make the native engine,
/// and the composition root (`AppShell`, which *can* depend on `EngineVLCKit`)
/// injects a `makeHybrid` closure that constructs a `VLCKitVideoEngine`. The view
/// model picks a ``CoreModels/PlaybackEngineKind`` via ``CoreModels/EngineRouter``
/// and calls the matching closure here.
///
/// The default value (``native``) supplies only the native engine, so existing
/// call sites that don't pass a factory keep their byte-for-byte current
/// behaviour (always `NativeVideoEngine`).
public struct EngineFactory {
    /// Builds the AVPlayer-backed engine. Always present.
    public var makeNative: @MainActor (CaptionSettings) -> any VideoEngine
    /// Builds the VLCKit-backed hybrid engine, or `nil` when this build doesn't
    /// link an engine for AVPlayer-incompatible media (then routing stays native).
    public var makeHybrid: (@MainActor (CaptionSettings) -> any VideoEngine)?
    /// Builds the Plozzigen engine (FFmpeg demux → HLS-fMP4 → AVPlayer), or `nil`
    /// when the engine isn't linked. Used for DoVi/Atmos MKV sources that need
    /// native AVPlayer rendering with full seek and bounded memory.
    public var makePlozzigen: (@MainActor () -> (any VideoEngine)?)?

    public init(
        makeNative: @escaping @MainActor (CaptionSettings) -> any VideoEngine = { NativeVideoEngine(captionSettings: $0) },
        makeHybrid: (@MainActor (CaptionSettings) -> any VideoEngine)? = nil,
        makePlozzigen: (@MainActor () -> (any VideoEngine)?)? = nil
    ) {
        self.makeNative = makeNative
        self.makeHybrid = makeHybrid
        self.makePlozzigen = makePlozzigen
    }

    /// Whether a hybrid engine is wired in. Drives the router's `hybridAvailable`
    /// and the cross-engine fallback so advertise ⇔ route stays in lockstep.
    public var hybridAvailable: Bool { makeHybrid != nil }

    /// Whether Plozzigen engine is wired in.
    public var plozzigenAvailable: Bool { makePlozzigen != nil }

    /// Native-only factory: the conservative default that preserves today's
    /// behaviour everywhere a hybrid engine isn't injected.
    public static let native = EngineFactory()
}
#endif
