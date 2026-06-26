#if canImport(AVFoundation)
import Foundation
import CoreModels

/// An optional capability a `VideoEngine` can adopt to expose its **live runtime
/// health** (decode path, frame drops, rendered fps) to the diagnostics overlay.
///
/// Kept separate from `VideoEngine` so the contract stays minimal: engines that
/// can't introspect their pipeline (e.g. the AVPlayer-based `NativeVideoEngine`,
/// which surfaces drops through `AVPlayerItem.accessLog()` instead) simply don't
/// conform, and the sampler falls back to its AVFoundation path. The mpv engine
/// conforms and reads the values straight off libmpv, which is the only way to
/// answer "is the device actually keeping up?" for that engine — its overlay was
/// previously metadata-only because there is no `AVPlayer` to sample.
///
/// `@MainActor` like the rest of the playback stack; the sampler polls this on
/// the same ~1s cadence as its other metrics.
@MainActor
public protocol PlaybackStatsProviding: AnyObject {
    /// A fresh snapshot of the engine's runtime health, or `nil` if nothing is
    /// playing yet / the engine can't report this tick. Must be cheap: it's
    /// called about once a second on the main actor.
    func sampleEngineStats() -> PlaybackEngineStats?
}
#endif
