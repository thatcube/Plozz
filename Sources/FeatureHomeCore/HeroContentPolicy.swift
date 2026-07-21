import CoreModels
import Foundation

/// Canonical text/facts/credits policy shared by Home and detail heroes.
public enum HeroContentPolicy {
    public static func homeDescription(
        for item: HeroPresentation
    ) -> String? {
        item.tagline ?? item.overview
    }

    public static func detailDescription(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> String? {
        focused.overview ?? root.overview ?? root.tagline
    }

    public static func ratingBadge(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> MediaBadge? {
        focused.ratingBadge ?? root.ratingBadge
    }

    public static func genres(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> [String] {
        GenreDisplayFormatter.displayNames(
            for: focused.genres.isEmpty ? root.genres : focused.genres
        )
    }

    public static func ratings(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> [ExternalRating] {
        focused.ratings.isEmpty ? root.ratings : focused.ratings
    }

    public static func detailFacts(
        focused: HeroPresentation
    ) -> [String] {
        let genres = Set(
            GenreDisplayFormatter.displayNames(for: focused.genres)
        )
        return focused.metadataComponents.filter { !genres.contains($0) }
    }

    public static func technicalBadges(
        focused: HeroPresentation,
        root: HeroPresentation,
        override: [MediaBadge]? = nil
    ) -> [MediaBadge] {
        if let override, !override.isEmpty {
            return override
        }
        return focused.technicalBadges.isEmpty
            ? root.technicalBadges
            : focused.technicalBadges
    }
}
