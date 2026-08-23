import CoreModels
import Foundation

/// Decides what may be written to the hero's launch snapshot and repainted in the
/// first frame of the next launch.
///
/// A snapshot is a promise that last session's answer is still true enough to
/// act on. For a title that is only *described* — its name, artwork, rating — it
/// is. For one that claims a **playback position** it is not: a resume goes stale
/// the moment anything is watched anywhere, including on another device, and a
/// slide restored from disk offering to resume a finished episode is worse than
/// showing nothing. Home applies the same rule to its cached Continue Watching
/// row; this is that rule in one enforceable place.
///
/// Applied to the **final** payload rather than the curated candidate, because a
/// title picks up per-server detail on its way to being persisted: metadata
/// enrichment fills sparse records, and the cross-server merge unions source
/// refs — each of which carries its own server's resume. A card whose own
/// `resumePosition` is `nil` can therefore still be resumable through one of its
/// sources, which `unifiedWatchState` will happily fold back onto it.
///
/// Also applied on **load**, so a snapshot written by a build that predates this
/// rule cannot repaint a stale position either.
public enum HeroDurableSnapshot {
    /// Whether this slide is safe to persist and repaint.
    ///
    /// The test is the app's own definition of "claims a position" —
    /// ``MediaItem/resumeProgressFraction``, which is what the hero's CTA reads to
    /// decide between Play and Resume, and what draws the progress capsule. Using
    /// anything narrower here (a bare `resumePosition` check, say) lets a slide
    /// through that the UI will still render as resumable: Jellyfin synthesises
    /// `playedPercentage` on part-watched series and seasons with no
    /// `resumePosition` at all, so a container drawn by Random, Watchlist or
    /// Recently Added is exactly the case that slips past.
    public static func isDurable(_ item: MediaItem) -> Bool {
        guard !claimsPosition(item) else { return false }
        return !item.sources.contains { source in
            var probe = item
            probe.resumePosition = source.resumePosition
            probe.playedPercentage = source.playedPercentage
            probe.isPlayed = source.isPlayed
            return claimsPosition(probe)
        }
    }

    /// Both halves of the disjunction are load-bearing. `resumeProgressFraction`
    /// is the CTA's own test, and catches a part-watched container that carries
    /// only a `playedPercentage`. It cannot stand alone, though: it needs a
    /// `runtime` to turn a position into a fraction, so a record whose runtime the
    /// list endpoint omitted reports no progress while still holding a real resume
    /// position that playback would honour.
    private static func claimsPosition(_ item: MediaItem) -> Bool {
        item.resumeProgressFraction != nil || (item.resumePosition ?? 0) > 0
    }

    /// The subset of `items` safe to persist and repaint, in order.
    public static func filter(_ items: [MediaItem]) -> [MediaItem] {
        items.filter(isDurable)
    }
}
