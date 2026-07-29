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
    ///
    /// A **container** — a season or a series — expresses progress differently. It
    /// has no resume position of its own, and its `playedPercentage` counts only
    /// *completed* episodes, so a season whose first episode is half-watched
    /// reports no percentage at all. Its progress is simply "started, not
    /// finished", which is what `hasBeenPlayed` records.
    ///
    /// Without this a part-watched season looked identical to an untouched one, so
    /// resolving "which season is the viewer on" fell through to "the first
    /// unwatched one" — Season 1 — even for someone midway through Season 3.
    public static func isInProgress(_ item: MediaItem) -> Bool {
        guard !item.isPlayed else { return false }
        if let percentage = item.playedPercentage, percentage > 0, percentage < 1 {
            return true
        }
        if let resume = item.resumePosition, resume > 0 {
            return true
        }
        switch item.kind {
        case .season, .series: return item.hasBeenPlayed
        default: return false
        }
    }

    /// The "next up" child to surface when a series/season detail loads.
    ///
    /// **Recency decides, not list order.** Someone watching Season 5 continues in
    /// Season 5 even if Season 1 was never touched — which is what Jellyfin's
    /// *Next Up* and Plex's *On Deck* both do. Ordering alone would send them back
    /// to the earliest gap, offering an episode they deliberately skipped.
    ///
    /// Selection order:
    ///   1. an in-progress item — the **most recently played** when several are
    ///      part-watched, rather than whichever sorts first;
    ///   2. the next unwatched item *after* the most recently completed one
    ///      (finished S5 · E10 → S5 · E11, regardless of gaps earlier in the show);
    ///   3. otherwise the first unwatched item — the only remaining gap;
    ///   4. otherwise the last item (everything is watched — offer the finale).
    ///
    /// `lastPlayedAt` drives steps 1 and 2 and is populated by every backend:
    /// Jellyfin from `UserData.LastPlayedDate`, Plex from `lastViewedAt`, shares
    /// from the watch record. Where it is missing the comparison degrades to list
    /// order, which is the old behaviour.
    ///
    /// Returns `nil` only for an empty list. The input order is treated as the
    /// display order, so callers should pass episodes/seasons already sorted.
    public static func nextUp(in items: [MediaItem]) -> MediaItem? {
        // Recency first, and for containers it is often the *only* signal that
        // works. A season whose sole progress is a part-watched episode reports
        // nothing: Jellyfin's `UnplayedItemCount` and Plex's `viewedLeafCount`
        // both count only *completed* children, so the season someone is actually
        // in the middle of looks untouched, while an earlier season with finished
        // episodes looks "in progress". Ranking by list order then picks the
        // earlier season — the show opens on Season 1 for someone watching
        // Season 3. `lastPlayedAt` is set whenever anything inside was played, so
        // it sees the case the counts miss.
        let unfinished = items.filter { !$0.isPlayed }
        if let recent = mostRecentlyPlayed(in: unfinished) {
            return recent
        }

        let inProgress = items.filter(isInProgress)
        if !inProgress.isEmpty {
            return mostRecentlyPlayed(in: inProgress) ?? inProgress.first
        }

        // Continue from wherever they actually were, not from the earliest gap.
        if let latest = mostRecentlyPlayed(in: items.filter(\.isPlayed)),
           let index = items.firstIndex(where: { $0.id == latest.id }),
           let following = items[items.index(after: index)...].first(where: { !$0.isPlayed }) {
            return following
        }

        if let unwatched = items.first(where: { !$0.isPlayed }) {
            return unwatched
        }
        return items.last
    }

    /// The most recently played of `items`, or `nil` when none carries a
    /// timestamp — in which case the caller falls back to list order.
    private static func mostRecentlyPlayed(in items: [MediaItem]) -> MediaItem? {
        items
            .compactMap { item in item.lastPlayedAt.map { (item: item, played: $0) } }
            .max { $0.played < $1.played }?
            .item
    }

    /// Whether the viewer has watched any part of this show.
    ///
    /// Read from the **seasons**, which are always loaded, rather than the
    /// episodes, which are only ever loaded one season at a time: someone who
    /// finished Season 1 and opens on Season 2 would look untouched, because
    /// every Season 2 episode is unwatched. A flat show with no season containers
    /// has its whole episode list to hand, so it answers from that instead.
    public static func hasStarted(seasons: [MediaItem], episodes: [MediaItem]) -> Bool {
        let pool = seasons.isEmpty ? episodes : seasons
        return pool.contains { $0.isPlayed || isInProgress($0) }
    }

    /// Whether every episode of this show has been watched.
    ///
    /// An episode part-way through disqualifies it even when every season reports
    /// played: someone rewatching a finished show is mid-episode, and that is a
    /// resume point. Without this, a show you have seen and are now rewatching
    /// reads as "finished" and offers to start over from episode 1 while you are
    /// nine episodes into the rewatch.
    ///
    /// Explicitly false for an empty list: `allSatisfy` is vacuously true on one,
    /// so an unloaded or genuinely empty show would otherwise report "finished".
    public static func isFinished(seasons: [MediaItem], episodes: [MediaItem]) -> Bool {
        guard !episodes.contains(where: isInProgress) else { return false }
        let pool = seasons.isEmpty ? episodes : seasons
        guard !pool.isEmpty else { return false }
        return pool.allSatisfy(\.isPlayed)
    }

    /// What the series page should rest on — the subject of the hero, and of the
    /// Play button, which are always the same thing.
    ///
    /// The show itself when there is no resume point to offer: either nothing has
    /// been watched, or all of it has and the pointer is stale. A finished series
    /// is treated as "start over", which is behaviourally identical to one never
    /// started. Otherwise the episode to resume.
    public static func restingHero(
        series: MediaItem,
        seasons: [MediaItem],
        episodes: [MediaItem]
    ) -> MediaItem {
        // An episode part-way through is a resume point whatever the aggregate
        // says. Checked before `hasStarted`/`isFinished` because those read the
        // *seasons*, which cannot see a rewatch: every season of a show you have
        // finished still reports played while you are mid-episode in it.
        let resuming = episodes.filter(isInProgress)
        if !resuming.isEmpty {
            return mostRecentlyPlayed(in: resuming) ?? resuming[0]
        }
        guard hasStarted(seasons: seasons, episodes: episodes),
              !isFinished(seasons: seasons, episodes: episodes)
        else { return series }
        return nextUp(in: episodes) ?? series
    }

    /// The season a restart begins from.
    ///
    /// The first non-special season, because season 0 holds specials and sorts
    /// ahead of season 1 — "start from the beginning" landing on a Christmas
    /// special is not what anyone means. Falls back to whatever is first when
    /// specials are all there is.
    public static func restartSeason(in seasons: [MediaItem]) -> MediaItem? {
        seasons.first { ($0.seasonNumber ?? 1) > 0 } ?? seasons.first
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

/// Resolves an episode-context entry against the active server's season/episode
/// objects. Provider ids differ across servers, but S/E ordinals remain stable.
public enum SeriesEpisodeEntry {
    public static func seasonID(
        initialEpisode: MediaItem?,
        initialSeasonID: String?,
        seasons: [MediaItem]
    ) -> String? {
        if let id = initialEpisode?.seasonID,
           seasons.contains(where: { $0.id == id }) {
            return id
        }
        if let number = initialEpisode?.seasonNumber,
           let season = seasons.first(where: { $0.seasonNumber == number }) {
            return season.id
        }
        if let initialSeasonID,
           seasons.contains(where: { $0.id == initialSeasonID }) {
            return initialSeasonID
        }
        return seasons.first?.id
    }

    public static func episode(
        matching initialEpisode: MediaItem?,
        in episodes: [MediaItem]
    ) -> MediaItem? {
        guard let initialEpisode else { return nil }
        if let exact = episodes.first(where: { $0.id == initialEpisode.id }) {
            return exact
        }
        if let season = initialEpisode.seasonNumber,
           let episode = initialEpisode.episodeNumber {
            if let exact = SeriesHeroNumbering.episode(
                matching: SeasonEpisodeRef(season: season, episode: episode),
                in: episodes
            ) {
                return exact
            }
            // `episodes` is already the selected season's scoped child list.
            // Some providers omit seasonNumber on those rows, so E-number is the
            // correct fallback here and cannot accidentally cross seasons.
            return episodes.first { $0.episodeNumber == episode }
        }
        if let episode = initialEpisode.episodeNumber {
            return episodes.first { $0.episodeNumber == episode }
        }
        return nil
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
