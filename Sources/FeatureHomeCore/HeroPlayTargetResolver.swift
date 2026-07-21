import CoreModels
import Foundation

public enum HeroPlayTargetResolver {
    public static func resolve(
        item: MediaItem,
        provider: any MediaProvider
    ) async -> MediaItem? {
        switch item.kind {
        case .movie, .episode, .video:
            return item
        case .series:
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
