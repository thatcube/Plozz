import Foundation

/// A kind of playable/browsable media item, provider-agnostic.
public enum MediaItemKind: String, Codable, Sendable {
    case movie
    case series
    case season
    case episode
    case video
    case folder
    case collection
    case unknown
}

/// A provider-agnostic media item.
///
/// Providers map their native item shapes (Jellyfin `BaseItemDto`, later Plex
/// `Metadata`) onto this type so feature code never imports a provider module.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: MediaItemKind
    public var overview: String?

    /// Series title for an episode, etc.
    public var parentTitle: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var productionYear: Int?

    /// Total runtime in seconds, if known.
    public var runtime: TimeInterval?
    /// Saved resume position in seconds.
    public var resumePosition: TimeInterval?
    /// Fractional watched progress in `0...1`, if the backend reports it.
    public var playedPercentage: Double?
    public var isPlayed: Bool

    /// Primary (poster) artwork.
    public var posterURL: URL?
    /// Wide/backdrop artwork.
    public var backdropURL: URL?
    /// Spoiler-safe parent artwork to use when this item has no image of its own
    /// (e.g. an episode with no thumbnail falls back to its series' backdrop).
    /// Never an episode's own frame, so it is safe to show even under spoilers.
    public var fallbackArtworkURL: URL?

    /// External/critical ratings (IMDb, Rotten Tomatoes, …), in their native
    /// scales. May be enriched asynchronously after the item first loads.
    public var ratings: [ExternalRating]

    /// External database identifiers (e.g. `["Imdb": "tt0111161", "Tmdb": "278"]`),
    /// used by enrichment services to look up additional ratings/metadata.
    public var providerIDs: [String: String]

    public init(
        id: String,
        title: String,
        kind: MediaItemKind,
        overview: String? = nil,
        parentTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        productionYear: Int? = nil,
        runtime: TimeInterval? = nil,
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        fallbackArtworkURL: URL? = nil,
        ratings: [ExternalRating] = [],
        providerIDs: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.overview = overview
        self.parentTitle = parentTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.productionYear = productionYear
        self.runtime = runtime
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.fallbackArtworkURL = fallbackArtworkURL
        self.ratings = ratings
        self.providerIDs = providerIDs
    }

    /// A human-friendly subtitle line, e.g. `S1 · E3` or the production year.
    public var subtitle: String? {
        if let season = seasonNumber, let episode = episodeNumber {
            return "S\(season) · E\(episode)"
        }
        if let parentTitle { return parentTitle }
        if let productionYear { return String(productionYear) }
        return nil
    }
}

/// A browsable library/collection root (Jellyfin "view").
public struct MediaLibrary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: MediaItemKind
    public var imageURL: URL?

    public init(id: String, title: String, kind: MediaItemKind, imageURL: URL? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.imageURL = imageURL
    }
}
