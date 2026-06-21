import Foundation
import CoreModels

/// Pure, UI-independent helpers for the "series resume" experience: choosing the
/// episode (or season) the user should jump back into, and formatting resume
/// timecodes. Kept free of SwiftUI so it compiles — and is unit-tested — on
/// every platform, including the Linux CI that runs `swift test`.
public enum SeriesResume {
    /// Whether `item` is partially watched and worth resuming: it has meaningful
    /// progress (a fractional `playedPercentage` strictly between 0 and 1, or a
    /// positive `resumePosition`) and has not been marked fully played.
    public static func isInProgress(_ item: MediaItem) -> Bool {
        guard !item.isPlayed else { return false }
        if let percentage = item.playedPercentage, percentage > 0, percentage < 1 {
            return true
        }
        if let resume = item.resumePosition, resume > 0 {
            return true
        }
        return false
    }

    /// The "next up" child to surface focus on when a series/season detail loads.
    ///
    /// Selection order:
    ///   1. the first in-progress item (so a half-watched episode is offered);
    ///   2. otherwise the first unwatched item (the next episode to start);
    ///   3. otherwise the last item (everything is watched — offer the finale).
    ///
    /// Returns `nil` only for an empty list. The input order is treated as the
    /// display order, so callers should pass episodes/seasons already sorted.
    public static func nextUp(in items: [MediaItem]) -> MediaItem? {
        if let inProgress = items.first(where: isInProgress) {
            return inProgress
        }
        if let unwatched = items.first(where: { !$0.isPlayed }) {
            return unwatched
        }
        return items.last
    }
}

/// Formats playback positions/durations as a compact timecode.
public enum PlaybackTimecode {
    /// Renders `seconds` as `m:ss` (under an hour) or `h:mm:ss` (an hour or
    /// more). Negative or non-finite inputs clamp to `0:00`.
    public static func string(from seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
