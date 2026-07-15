import Foundation
import CoreModels

/// The read-only catalog surface `ShareProvider` needs from its app-owned SQLite
/// index. It returns only public/core models (`MediaItem`, counts, ids) and never
/// exposes the concrete `ShareCatalogStore` actor, so the provider — and its
/// tests — depend on a narrow capability rather than the 3k-line store.
///
/// Every requirement is `async`: the production witness is the actor-isolated
/// `ShareCatalogStore`, and fakes can answer synchronously.
public protocol ShareCatalogReading: Sendable {
    /// Per-kind indexed counts used to decide which synthetic libraries appear.
    func libraryCounts() async -> (movies: Int, tvSeries: Int, animeSeries: Int)

    /// Recently-added items (by first-discovery date) for the Home hot path.
    func latest(limit: Int) async -> [MediaItem]

    /// Indexed search over catalog titles.
    func search(query: String, limit: Int) async -> [MediaItem]

    /// One page of movies for the Movies grid.
    func movies(offset: Int, limit: Int) async -> [MediaItem]

    /// One page of series for a TV/Anime grid.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) async -> [MediaItem]

    /// Exact indexed movie count (for stable grid sizing).
    func movieCount() async -> Int

    /// Exact indexed series count for a library.
    func seriesCount(in library: CatalogLibrary) async -> Int

    /// Transport-free page for local description indexing.
    func searchCatalogItems(
        libraryID: String,
        kind: MediaItemKind,
        offset: Int,
        limit: Int
    ) async -> MediaPage

    /// Seasons under a series.
    func seasons(seriesKey: String) async -> [MediaItem]

    /// Episodes under a season.
    func episodes(seriesKey: String, season: Int) async -> [MediaItem]

    /// A single indexed item, or nil for un-indexed raw file ids.
    func item(id: String) async -> MediaItem?

    /// The default playable file rel-path for a logical movie key.
    func defaultMovieRelPath(forKey key: String) async -> String?

    /// Collapses a legacy/member-file id onto its canonical logical id.
    func canonicalItemID(_ id: String) async -> String

    /// Maps requested ids to the stored watch-state alias ids the watch store
    /// keys on (so several version records fold onto one canonical id).
    func watchStateAliases(for itemIDs: [String]) async -> [String: String]

    /// Whether a raw file id is a known indexed file asset.
    func containsFileAsset(id: String) async -> Bool
}

/// The concrete SQLite-backed store is the production witness. Its methods are
/// synchronous actor-isolated reads, which satisfy the `async` requirements when
/// the store is used through `any ShareCatalogReading`.
extension ShareCatalogStore: ShareCatalogReading {}

public extension ShareCatalogReading {
    func searchCatalogItems(
        libraryID: String,
        kind: MediaItemKind,
        offset: Int,
        limit: Int
    ) async -> MediaPage {
        MediaPage(items: [], startIndex: offset, totalCount: 0)
    }
}
