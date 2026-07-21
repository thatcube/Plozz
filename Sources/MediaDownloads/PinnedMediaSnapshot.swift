import CoreModels
import Foundation

/// A small, PINNED copy of the metadata an offline card needs to render without
/// any server — captured at download time so browsing downloads works fully
/// offline.
///
/// ## Privacy / forward-compatibility (guardrail G2)
/// This snapshot must **never** persist a raw library/filesystem path or a
/// credential-bearing/expiring URL. Artwork is referenced only by
/// ``artworkFileName`` — the *relative leaf filename* of an image copied into the
/// download's own pinned folder (e.g. `poster.jpg`). That reference leaks nothing
/// about the user's library layout and never expires, and it stays valid if the
/// pinned folder is relocated wholesale.
public struct PinnedMediaSnapshot: Codable, Sendable, Hashable {
    public var title: String
    public var kind: MediaItemKind
    public var year: Int?
    public var sourceAccountID: String?
    public var sourceItemID: String?
    /// Relative leaf filename of the poster/artwork inside this download's pinned
    /// folder, or `nil` when no artwork was captured. NEVER an absolute path or a
    /// server URL (see the type doc).
    public var artworkFileName: String?
    /// Series title for an episode download (the show name, e.g. "One Piece"),
    /// used to group episodes under their show in the Downloads library. `nil`
    /// for movies and for records pinned before snapshot enrichment shipped.
    public var seriesTitle: String?
    /// Stable series identifier for grouping seasons of the same show together.
    /// `nil` for movies and legacy records.
    public var seriesID: String?
    /// Season/episode ordinals for an episode download, used for grouped
    /// season sections and "S1 · E5"-style labels. `nil` for movies/legacy.
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    /// The item's cross-provider IDs (TVDB/TMDB/Jellyfin/etc.), captured so a
    /// reconstructed offline item reproduces the same identity the pinned file
    /// was keyed by — letting downloaded episodes (and their neighbors) resolve
    /// straight from disk. Empty for records pinned before this shipped.
    public var providerIDs: [String: String]

    public init(
        title: String,
        kind: MediaItemKind,
        year: Int? = nil,
        sourceAccountID: String? = nil,
        sourceItemID: String? = nil,
        artworkFileName: String? = nil,
        seriesTitle: String? = nil,
        seriesID: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        providerIDs: [String: String] = [:]
    ) {
        self.title = title
        self.kind = kind
        self.year = year
        self.sourceAccountID = sourceAccountID
        self.sourceItemID = sourceItemID
        self.artworkFileName = artworkFileName
        self.seriesTitle = seriesTitle
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.providerIDs = providerIDs
    }

    private enum CodingKeys: String, CodingKey {
        case title, kind, year, sourceAccountID, sourceItemID, artworkFileName
        case seriesTitle, seriesID, seasonNumber, episodeNumber, providerIDs
    }

    /// Custom decode so records pinned before the enrichment fields shipped keep
    /// loading: every additive field is optional/defaulted. Without this, the
    /// non-optional `providerIDs` would make old records fail to decode and take
    /// the whole downloads store down (`DurableLocalStateError`).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        sourceAccountID = try container.decodeIfPresent(
            String.self, forKey: .sourceAccountID
        )
        sourceItemID = try container.decodeIfPresent(
            String.self, forKey: .sourceItemID
        )
        artworkFileName = try container.decodeIfPresent(
            String.self, forKey: .artworkFileName
        )
        seriesTitle = try container.decodeIfPresent(
            String.self, forKey: .seriesTitle
        )
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
        seasonNumber = try container.decodeIfPresent(
            Int.self, forKey: .seasonNumber
        )
        episodeNumber = try container.decodeIfPresent(
            Int.self, forKey: .episodeNumber
        )
        providerIDs = try container.decodeIfPresent(
            [String: String].self, forKey: .providerIDs
        ) ?? [:]
    }
}

public extension PinnedMediaSnapshot {
    /// Builds a snapshot from a live `MediaItem`, copying only portable, non-secret
    /// fields (title/kind/year plus episode grouping ordinals and provider IDs).
    /// Artwork is attached separately by the downloader once the image file has
    /// been pinned.
    init(item: MediaItem) {
        self.init(
            title: item.title,
            kind: item.kind,
            year: item.productionYear,
            sourceAccountID: item.sourceAccountID,
            sourceItemID: item.id,
            artworkFileName: nil,
            seriesTitle: item.parentTitle,
            seriesID: item.seriesID,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            providerIDs: item.providerIDs
        )
    }
}
