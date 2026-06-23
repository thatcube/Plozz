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
    public let title: String
    /// Alternate/original title (e.g. romaji), tried when the primary misses.
    public let alternateTitle: String?
    public let year: Int?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let animeIDs: AnimeIDs
    /// The full provider-id bag (TMDb/IMDb/TVDB/SeriesTmdb/…) for direct lookups.
    public let providerIDs: [String: String]

    public init(
        contentType: ContentType,
        kind: MediaItemKind,
        title: String,
        alternateTitle: String?,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        animeIDs: AnimeIDs,
        providerIDs: [String: String]
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
}
