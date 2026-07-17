import Foundation

/// Pure duration/watched-percentage arithmetic for progress reporting, resume
/// points, and Trakt scrobbling. Extracted from `PlayerViewModel` so the rules
/// that keep resume/scrobble honest (which duration source wins, how a stop
/// position maps to a percentage) can be unit-tested without an engine, a
/// provider, or a running player.
///
/// Provider-agnostic and engine-agnostic: it operates only on plain
/// `TimeInterval`s the caller reads off whichever engine (native AVPlayer or
/// Plozzigen) and item is live, so it behaves identically for Plex and Jellyfin.
enum WatchProgressMath {
    /// The best-known playback duration: the first finite, positive value among
    /// the engine's reported duration, the controls' duration, and the item's
    /// declared runtime (in that order). `nil` when none is known.
    ///
    /// Mirrors `PlayerViewModel.knownPlaybackDuration()` exactly — the engine is
    /// trusted first (it has the real container duration once loaded), then the
    /// controls mirror, then the catalog runtime as a last resort.
    static func knownDuration(
        engineDuration: TimeInterval,
        controlsDuration: TimeInterval,
        itemRuntime: TimeInterval?
    ) -> TimeInterval? {
        let candidates = [engineDuration, controlsDuration, itemRuntime ?? 0]
        return candidates.first { $0.isFinite && $0 > 0 }
    }

    /// Watched percentage (0...100) for `position` over the item's duration,
    /// preferring the engine's known duration and falling back to the item
    /// runtime. Returns `0` when the position is invalid or no duration is known.
    ///
    /// Note this deliberately does **not** consult the controls duration (unlike
    /// ``knownDuration(engineDuration:controlsDuration:itemRuntime:)``): the
    /// scrobble percent is computed straight off the authoritative engine
    /// duration or the catalog runtime, matching the original
    /// `PlayerViewModel.watchedPercent(at:)`.
    static func watchedPercent(
        position: TimeInterval,
        engineDuration: TimeInterval,
        itemRuntime: TimeInterval?
    ) -> Double {
        guard position.isFinite, position >= 0 else { return 0 }
        let duration = (engineDuration.isFinite && engineDuration > 0)
            ? engineDuration
            : itemRuntime
        guard let duration, duration > 0 else { return 0 }
        return min(max(position / duration * 100, 0), 100)
    }
}
