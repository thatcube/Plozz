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

/// A season+episode ordinal pair, used to re-locate "the same episode" on a
/// different server (where per-server ids differ) — e.g. preserving the fronted
/// episode across an in-place cross-server switch.
public struct SeasonEpisodeRef: Equatable, Sendable {
    public let season: Int
    public let episode: Int
    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }
}

/// Pure, UI-independent derivation of the `S{n} · E{m}` numbering a TV-show hero
/// must always show when an *episode* is fronted. Some list/search/seed episodes
/// arrive missing their `seasonNumber`/`episodeNumber` (they know only their own
/// id), so the badge would silently disappear. This fills the gap from the best
/// available source, in priority order, and never invents a wrong number.
public enum SeriesHeroNumbering {
    /// Returns `hero` with its `seasonNumber`/`episodeNumber` filled in as
    /// robustly as possible so `MediaItem.subtitle` emits the `S · E` badge.
    ///
    /// Non-episode heroes (the series or a season) are returned unchanged.
    /// Derivation order for each missing field:
    ///   1. the hero's own value (kept when present);
    ///   2. its richer **loaded counterpart**, matched by id across every loaded
    ///      season — the authoritative numbers the rail itself shows;
    ///   3. `seasonNumber` from the owning/selected **season** item;
    ///   4. `episodeNumber` from the episode's **position** within its season's
    ///      loaded episode list (a correct ordinal fallback).
    public static func numberedHero(
        _ hero: MediaItem,
        seasons: [MediaItem],
        loadedEpisodesBySeason: [String: [MediaItem]],
        selectedSeasonID: String?,
        selectedSeasonPool: [MediaItem]
    ) -> MediaItem {
        guard hero.kind == .episode else { return hero }
        var copy = hero
        var owningSeasonID = copy.seasonID

        // 2) Adopt the richer loaded counterpart's numbers (matched by id), and
        //    learn which season it actually sits in.
        if copy.seasonNumber == nil || copy.episodeNumber == nil || owningSeasonID == nil {
            for (seasonID, episodes) in loadedEpisodesBySeason {
                guard let index = episodes.firstIndex(where: { $0.id == hero.id }) else { continue }
                let match = episodes[index]
                if copy.seasonNumber == nil { copy.seasonNumber = match.seasonNumber }
                if copy.episodeNumber == nil { copy.episodeNumber = match.episodeNumber ?? (index + 1) }
                if owningSeasonID == nil { owningSeasonID = seasonID }
                break
            }
        }

        // 3) seasonNumber from the owning (or selected) season item.
        if copy.seasonNumber == nil {
            let seasonID = owningSeasonID ?? selectedSeasonID
            if let number = seasons.first(where: { $0.id == seasonID })?.seasonNumber {
                copy.seasonNumber = number
            }
        }

        // 4) episodeNumber from the episode's position in its season's pool.
        if copy.episodeNumber == nil {
            let pool = (owningSeasonID ?? selectedSeasonID)
                .flatMap { loadedEpisodesBySeason[$0] } ?? selectedSeasonPool
            if let index = pool.firstIndex(where: { $0.id == hero.id }) {
                copy.episodeNumber = index + 1
            }
        }

        return copy
    }

    /// Finds the episode in `pool` matching a `SeasonEpisodeRef`, used to re-front
    /// "the same episode" after an in-place cross-server switch (per-server ids
    /// differ, so we match by season+episode NUMBER). Returns `nil` when absent.
    public static func episode(
        matching target: SeasonEpisodeRef,
        in pool: [MediaItem]
    ) -> MediaItem? {
        pool.first {
            $0.seasonNumber == target.season && $0.episodeNumber == target.episode
        }
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
