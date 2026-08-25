import Foundation
import CoreModels

/// The visual role of a piece of artwork. Drives both which provider capability is
/// queried and which CDN image size is requested.
public enum ArtworkKind: String, Sendable, Hashable, CaseIterable {
    /// Full-bleed wide background behind the detail hero (16:9 / banner).
    case hero
    /// Vertical key art / poster (~2:3).
    case poster
    /// A single 16:9 still for one episode (the real "episode thumbnail").
    case thumbnail
    /// Transparent title/clear-logo PNG.
    case logo
}

/// A provider-agnostic, `Sendable` snapshot of everything a metadata provider
/// needs to resolve artwork for one item, normalized away from the backend shape.
///
/// Built once from a ``MediaItem`` so providers never re-derive the same fields
/// (series-vs-episode title, season/episode numbers, the relevant external ids).
public struct MetadataQuery: Sendable, Hashable {
    public let contentType: ContentType
    public let kind: MediaItemKind
    /// The title to search by. For an episode/season this is the *series* title
    /// (providers resolve show-level art, never an episode name).
    public let title: String  // l10n:content — media title used as an external-provider lookup key
    public let alternateTitle: String?
    public let year: Int?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let animeIDs: AnimeIDs
    /// The full provider-id bag (TMDb/IMDb/TVDB/SeriesTmdb/…) for direct lookups.
    public let providerIDs: [String: String]
    /// On-disk episode titles, when the caller scanned files itself. Lets a provider
    /// settle a same-name collision by content — the only evidence available for a
    /// show whose year is unknown, which is most of them (a series folder carries no
    /// year). Empty for a server-backed item, which already resolved its own identity.
    public let episodeHints: [SeriesEpisodeHint]
    /// Extra, usually more specific titles to try before ``title`` (a generic folder
    /// "Avatar" alongside the filenames' "Avatar The Last Airbender").
    public let titleAlternates: [String]

    public init(
        contentType: ContentType,
        kind: MediaItemKind,
        title: String,  // l10n:content — media title used as an external-provider lookup key
        alternateTitle: String?,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        animeIDs: AnimeIDs,
        providerIDs: [String: String],
        episodeHints: [SeriesEpisodeHint] = [],
        titleAlternates: [String] = []
    ) {
        self.contentType = contentType
        self.kind = kind
        self.title = title
        self.alternateTitle = alternateTitle
        self.year = year
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.animeIDs = animeIDs
        self.providerIDs = providerIDs
        self.episodeHints = episodeHints
        self.titleAlternates = titleAlternates
    }

    /// Identity deliberately excludes ``episodeHints`` and ``titleAlternates``: they
    /// describe how to break a tie, not what is being asked for. Two queries for the
    /// same show are the same query whether or not the caller could offer help, so
    /// gathering more hints must never split a cache entry or a dedupe key.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentType == rhs.contentType && lhs.kind == rhs.kind && lhs.title == rhs.title
            && lhs.alternateTitle == rhs.alternateTitle && lhs.year == rhs.year
            && lhs.seasonNumber == rhs.seasonNumber && lhs.episodeNumber == rhs.episodeNumber
            && lhs.animeIDs == rhs.animeIDs && lhs.providerIDs == rhs.providerIDs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(contentType)
        hasher.combine(kind)
        hasher.combine(title)
        hasher.combine(alternateTitle)
        hasher.combine(year)
        hasher.combine(seasonNumber)
        hasher.combine(episodeNumber)
        hasher.combine(animeIDs)
        hasher.combine(providerIDs)
    }

    /// The same query asked about the **show** rather than one of its episodes.
    ///
    /// A Continue Watching slide is an episode, but "when is the next one" is a
    /// property of the series. Left as-is, the episode's season/episode numbers land
    /// in the cache key (`…|s2e10`), so it would neither reuse the schedule the
    /// series detail page already fetched nor store anything the show could use —
    /// one cache entry per episode, all of them answering the same question.
    ///
    /// Series-scoped ids are promoted over the episode's own, which identify the
    /// episode and would resolve to the wrong record entirely.
    public var seriesScoped: Self {
        guard kind == .season || kind == .episode else { return self }
        var ids = providerIDs
        for (_, base) in Self.seriesIDPromotions {
            ids.removeProviderID(base)
        }
        for (series, base) in Self.seriesIDPromotions {
            if let value = ids.providerID(series) { ids[base.canonicalKey] = value }
        }
        return Self(
            contentType: contentType,
            kind: .series,
            title: title,
            alternateTitle: alternateTitle,
            year: year,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: animeIDs,
            providerIDs: ids,
            episodeHints: episodeHints,
            titleAlternates: titleAlternates
        )
    }

    /// Series-scoped id namespaces and the show-level namespace each supplies.
    private static let seriesIDPromotions: [(ProviderIDNamespace, ProviderIDNamespace)] = [
        (.seriesImdb, .imdb), (.seriesTmdb, .tmdb), (.seriesTvdb, .tvdb),
        (.seriesTvmaze, .tvmaze), (.seriesAniList, .aniList),
        (.seriesMal, .myAnimeList), (.seriesAniDB, .aniDB),
    ]

    /// A copy carrying on-disk disambiguation evidence a file-scanning caller holds.
    public func offering(
        episodeHints: [SeriesEpisodeHint] = [],
        titleAlternates: [String] = []
    ) -> Self {
        Self(
            contentType: contentType,
            kind: kind,
            title: title,
            alternateTitle: alternateTitle,
            year: year,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            animeIDs: animeIDs,
            providerIDs: providerIDs,
            episodeHints: episodeHints,
            titleAlternates: titleAlternates
        )
    }

    /// Normalizes a ``MediaItem`` into a query: classifies its content type and
    /// picks the show-level title for season/episode items.
    public init(_ item: MediaItem) {
        let type = ContentClassifier.classify(item)
        let showTitle: String
        switch item.kind {
        case .season, .episode:
            showTitle = item.parentTitle ?? item.title
        default:
            showTitle = item.title
        }
        // TV uses the series' air range, not an episode air date, so only movies
        // pass a year into title searches.
        let searchYear: Int? = (item.kind == .movie || item.kind == .video) ? item.productionYear : nil
        self.init(
            contentType: type,
            kind: item.kind,
            title: showTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            alternateTitle: nil,
            year: searchYear,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            animeIDs: AnimeIDs(from: item),
            providerIDs: item.providerIDs
        )
    }

    /// Whether the query is for the `tv` namespace (series/season/episode) rather
    /// than `movie`.
    public var isTV: Bool {
        switch kind {
        case .movie, .video: return false
        default: return true
        }
    }

    /// A stable cache identity for this query at a given ``ArtworkKind``: prefers a
    /// concrete external id so two items for the same show share one cached lookup,
    /// falling back to a normalized title (+year, +SxE for thumbnails).
    public func cacheKey(for kind: ArtworkKind) -> String {
        var parts: [String] = [contentType.rawValue, kind.rawValue]
        if let anilist = animeIDs.anilist { parts.append("anilist:\(anilist)") }
        else if let mal = animeIDs.mal { parts.append("mal:\(mal)") }
        else if let tmdb = providerIDs.providerID(.tmdb) ?? providerIDs.providerID(.seriesTmdb) { parts.append("tmdb:\(tmdb)") }
        else if let imdb = providerIDs.providerID(.imdb) { parts.append("imdb:\(imdb)") }
        else { parts.append("t:\(title.lowercased())|y:\(year.map(String.init) ?? "")") }
        if kind == .thumbnail, let s = seasonNumber, let e = episodeNumber {
            parts.append("s\(s)e\(e)")
        }
        return parts.joined(separator: "|")
    }
}

/// One source of artwork for a content type. Implementations are free, keyless,
/// per-IP APIs wherever possible (so they scale to any number of users), with the
/// optional TMDb tier behind a self-hostable proxy.
public protocol ArtworkProvider: Sendable {
    /// A short stable identifier, for logging/cache scoping.
    var id: String { get }
    /// Returns a URL for `kind` art matching `query`, or `nil` if this provider
    /// can't serve it. Must never throw — enrichment is always best-effort.
    func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL?
    /// Ordered candidates for `kind`, best first, up to `limit`.
    ///
    /// A hero draws the show's logo over its backdrop, and the Home hero and the
    /// detail page want *different* pictures — so a provider that holds several
    /// needs a way to offer them. One answer per provider made that impossible:
    /// both screens asked for `.hero`, got the same single URL, and the four
    /// textless backdrops TMDb had already fetched were discarded one layer up.
    ///
    /// Defaults to the single answer ``artworkURL(_:for:)`` gives, so a provider
    /// with only one picture needs no change and costs no extra request.
    func artworkURLs(_ kind: ArtworkKind, for query: MetadataQuery, limit: Int) async -> [URL]
}

extension ArtworkProvider {
    public func artworkURLs(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        limit: Int
    ) async -> [URL] {
        guard limit > 0, let url = await artworkURL(kind, for: query) else { return [] }
        return [url]
    }
}
