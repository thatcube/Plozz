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

    /// The content/age-classification certificate, e.g. `TV-14`, `PG-13`, `R`.
    /// Provider-native string (Jellyfin `OfficialRating`); `nil` when unrated or
    /// unreported. Rendered as an outlined badge on the detail hero.
    public var officialRating: String?

    /// Genre labels for the item, e.g. `["Action", "Adventure"]`. Ordered as the
    /// provider returns them; the detail metadata line shows the first few.
    public var genres: [String]

    /// For an episode, the id of its owning series, enabling a "Go to Series"
    /// jump from anywhere the episode appears. `nil` for non-episodes or when the
    /// provider doesn't report it.
    public var seriesID: String?

    /// For an episode, the id of its owning season, enabling a "Go to Season"
    /// jump (e.g. from a Continue Watching card). `nil` for non-episodes or when
    /// the provider doesn't report it.
    public var seasonID: String?

    /// Total runtime in seconds, if known.
    public var runtime: TimeInterval?
    /// Saved resume position in seconds.
    public var resumePosition: TimeInterval?
    /// Fractional watched progress in `0...1`, if the backend reports it.
    public var playedPercentage: Double?
    public var isPlayed: Bool

    /// Primary (poster) artwork.
    public var posterURL: URL?
    /// The owning series' vertical poster, for episodes. Lets episode cards shown
    /// in a poster grid (Home "Recently Added", library) display the show poster
    /// instead of the episode's own 16:9 still. `nil` for non-episodes.
    public var seriesPosterURL: URL?
    /// Wide/backdrop artwork.
    public var backdropURL: URL?
    /// A higher-resolution backdrop sized for the full-bleed detail hero. Cards
    /// keep using `backdropURL` (a smaller, rail-friendly size); only the hero
    /// reaches for this. `nil` falls back to `backdropURL`.
    public var heroBackdropURL: URL?
    /// Spoiler-safe parent artwork to use when this item has no image of its own
    /// (e.g. an episode with no thumbnail falls back to its series' backdrop).
    /// Never an episode's own frame, so it is safe to show even under spoilers.
    public var fallbackArtworkURL: URL?
    /// Stylized title/logo art (a transparent "clearLogo" PNG) for the detail
    /// hero. For episodes/seasons this is the owning series' logo. `nil` when the
    /// provider has no logo; callers then fall back to TMDb or plain text.
    public var logoURL: URL?

    /// External/critical ratings (IMDb, Rotten Tomatoes, …), in their native
    /// scales. May be enriched asynchronously after the item first loads.
    public var ratings: [ExternalRating]

    /// External database identifiers (e.g. `["Imdb": "tt0111161", "Tmdb": "278"]`),
    /// used by enrichment services to look up additional ratings/metadata.
    public var providerIDs: [String: String]

    /// Source-of-truth technical facts about the underlying file (resolution,
    /// HDR/Dolby Vision range, audio codec/channels, …) when the provider reports
    /// them on the detail fetch. Powers the "4K · Dolby Vision · Dolby Atmos"
    /// technical badge row on the detail hero. `nil` for items fetched without
    /// stream metadata (e.g. rows/cards) and for containers (series/season) that
    /// have no single media file.
    public var mediaInfo: MediaSourceMetadata?

    /// The `Account.id` this item was fetched from, stamped by the Home/Search
    /// aggregator when content from several providers is merged into one row.
    ///
    /// Providers never set this (they don't know app account ids) — it is `nil`
    /// for items returned directly by a single provider and only populated at the
    /// aggregated entry points, so callers can route a tapped item back to its
    /// owning provider. Once you drill into a single-provider subtree the field
    /// is irrelevant and may be `nil`.
    public var sourceAccountID: String?

    /// Other `Account.id`s that also hold this same title, populated when the
    /// Search aggregator de-duplicates a result that exists on several servers
    /// (e.g. the same movie on both a Jellyfin and a Plex account). The primary
    /// source stays in `sourceAccountID`; these are fallbacks so playback can
    /// still resolve the item if the primary server is unavailable. Empty for
    /// non-merged items.
    public var additionalSourceAccountIDs: [String]

    /// Every account this item can be played from, primary first: the merged
    /// `sourceAccountID` followed by any de-duplicated alternates.
    public var allSourceAccountIDs: [String] {
        (sourceAccountID.map { [$0] } ?? []) + additionalSourceAccountIDs
    }

    public init(
        id: String,
        title: String,
        kind: MediaItemKind,
        overview: String? = nil,
        parentTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        productionYear: Int? = nil,
        officialRating: String? = nil,
        genres: [String] = [],
        seriesID: String? = nil,
        seasonID: String? = nil,
        runtime: TimeInterval? = nil,
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false,
        posterURL: URL? = nil,
        seriesPosterURL: URL? = nil,
        backdropURL: URL? = nil,
        heroBackdropURL: URL? = nil,
        fallbackArtworkURL: URL? = nil,
        logoURL: URL? = nil,
        ratings: [ExternalRating] = [],
        providerIDs: [String: String] = [:],
        mediaInfo: MediaSourceMetadata? = nil,
        sourceAccountID: String? = nil,
        additionalSourceAccountIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.overview = overview
        self.parentTitle = parentTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.productionYear = productionYear
        self.officialRating = officialRating
        self.genres = genres
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.runtime = runtime
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.posterURL = posterURL
        self.seriesPosterURL = seriesPosterURL
        self.backdropURL = backdropURL
        self.heroBackdropURL = heroBackdropURL
        self.fallbackArtworkURL = fallbackArtworkURL
        self.logoURL = logoURL
        self.ratings = ratings
        self.providerIDs = providerIDs
        self.mediaInfo = mediaInfo
        self.sourceAccountID = sourceAccountID
        self.additionalSourceAccountIDs = additionalSourceAccountIDs
    }

    /// Custom decoding so `additionalSourceAccountIDs` (added after items were
    /// first persisted/cached) defaults to empty when absent, keeping older
    /// encoded `MediaItem`s decodable. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        officialRating = try container.decodeIfPresent(String.self, forKey: .officialRating)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
        seasonID = try container.decodeIfPresent(String.self, forKey: .seasonID)
        runtime = try container.decodeIfPresent(TimeInterval.self, forKey: .runtime)
        resumePosition = try container.decodeIfPresent(TimeInterval.self, forKey: .resumePosition)
        playedPercentage = try container.decodeIfPresent(Double.self, forKey: .playedPercentage)
        isPlayed = try container.decodeIfPresent(Bool.self, forKey: .isPlayed) ?? false
        posterURL = try container.decodeIfPresent(URL.self, forKey: .posterURL)
        seriesPosterURL = try container.decodeIfPresent(URL.self, forKey: .seriesPosterURL)
        backdropURL = try container.decodeIfPresent(URL.self, forKey: .backdropURL)
        heroBackdropURL = try container.decodeIfPresent(URL.self, forKey: .heroBackdropURL)
        fallbackArtworkURL = try container.decodeIfPresent(URL.self, forKey: .fallbackArtworkURL)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        ratings = try container.decodeIfPresent([ExternalRating].self, forKey: .ratings) ?? []
        providerIDs = try container.decodeIfPresent([String: String].self, forKey: .providerIDs) ?? [:]
        mediaInfo = try container.decodeIfPresent(MediaSourceMetadata.self, forKey: .mediaInfo)
        sourceAccountID = try container.decodeIfPresent(String.self, forKey: .sourceAccountID)
        additionalSourceAccountIDs = try container.decodeIfPresent([String].self, forKey: .additionalSourceAccountIDs) ?? []
    }

    /// Returns a copy of this item tagged as belonging to `accountID`, used by the
    /// aggregator to stamp merged rows with their owning account.
    public func taggingSource(_ accountID: String) -> MediaItem {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
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

    /// The `Account.id` this library was fetched from, stamped by the aggregator
    /// so a tapped library can be browsed against its owning provider. `nil` when
    /// returned directly by a single provider.
    public var sourceAccountID: String?

    public init(id: String, title: String, kind: MediaItemKind, imageURL: URL? = nil, sourceAccountID: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.imageURL = imageURL
        self.sourceAccountID = sourceAccountID
    }

    /// Returns a copy of this library tagged as belonging to `accountID`.
    public func taggingSource(_ accountID: String) -> MediaLibrary {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }
}
