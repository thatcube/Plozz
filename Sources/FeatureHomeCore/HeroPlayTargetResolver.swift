import CoreModels
import Foundation

public enum HeroPlayTargetResolver {
    /// What a "Play" tap should actually start for `item`.
    ///
    /// A whole series or season can never be played: the container holds no media, so
    /// Jellyfin answers `PlaybackInfo` with a 500 and Plex reports `notFound` —
    /// both surfacing to the viewer as a generic playback error. Every platform
    /// must therefore resolve it to its next-up/resume EPISODE before
    /// handing it to the player, which is what this does. Returns `nil` when no
    /// episode can be resolved (the caller should open the show instead of
    /// starting playback).
    ///
    /// Unlike ``resolve(item:provider:)`` this also stamps the resolved episode
    /// with the original item's account, so best-source routing and playback
    /// address the server the show actually came from. Prefer this at Play sites.
    public static func playbackTarget(
        for item: MediaItem,
        provider: any MediaProvider
    ) async -> MediaItem? {
        guard var target = await resolve(item: item, provider: provider) else {
            return nil
        }
        if target.sourceAccountID == nil, let accountID = item.sourceAccountID {
            target = target.taggingSource(accountID)
        }
        return target
    }

    public static func resolve(
        item: MediaItem,
        provider: any MediaProvider
    ) async -> MediaItem? {
        switch item.kind {
        case .movie, .episode, .video:
            return item
        case .series, .season:
            // A season is resolved by the same walk: `children(of:)` returns its
            // episodes directly, so the loose-episode branch below picks next-up
            // without ever descending into the season loop.
            break
        default:
            return nil
        }

        let children: [MediaItem]
        do {
            children = try await provider.children(of: item.id)
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let looseEpisodes = children.filter { $0.kind == .episode }
        if !looseEpisodes.isEmpty {
            return SeriesResume.nextUp(in: looseEpisodes)
        }

        let seasons = children
            .filter { $0.kind == .season }
            .sorted {
                ($0.seasonNumber ?? .max) < ($1.seasonNumber ?? .max)
            }
        var firstUnwatched: MediaItem?
        var lastEpisode: MediaItem?
        for season in seasons {
            guard !Task.isCancelled else { return nil }
            guard let episodes = try? await provider.children(of: season.id),
                  !episodes.isEmpty else {
                continue
            }
            if let inProgress = episodes.first(where: SeriesResume.isInProgress) {
                return inProgress
            }
            if firstUnwatched == nil {
                firstUnwatched = episodes.first { !$0.isPlayed }
            }
            lastEpisode = episodes.last
        }
        return firstUnwatched ?? lastEpisode
    }
}
