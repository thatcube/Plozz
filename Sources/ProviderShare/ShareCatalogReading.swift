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

    /// Seasons under a series.
    func seasons(seriesKey: String) async -> [MediaItem]

    /// Episodes under a season.
    func episodes(seriesKey: String, season: Int) async -> [MediaItem]

    /// Every episode file in a series, keyed for watch-state lookup and grouped by
    /// season and *logical* episode, so a season container's played state can be
    /// rolled up from its episodes in one pass instead of a query per season.
    func episodeWatchIdentities(seriesKey: String) async -> [(season: Int, logicalKey: String, fileID: String)]

    /// A single indexed item, or nil for un-indexed raw file ids.
    func item(id: String) async -> MediaItem?

    /// Items whose persisted cast includes this person, by TMDb id or by name.
    /// Fully local — a share resolves its cast at scan time, so a person page
    /// works offline and needs no third party at read time.
    ///
    /// Defaulted, so a conformer with no cast to search (test doubles, readers
    /// built before this existed) reports none rather than failing to compile.
    func itemsWithPerson(id personID: String?, name: String, limit: Int) async -> [MediaItem]

    /// The default playable file rel-path for a logical movie key.
    func defaultMovieRelPath(forKey key: String) async -> String?

    /// Collapses a legacy/member-file id onto its canonical logical id.
    func canonicalItemID(_ id: String) async -> String

    /// Maps requested ids to the stored watch-state alias ids the watch store
    /// keys on (so several version records fold onto one canonical id).
    func watchStateAliases(for itemIDs: [String]) async -> [String: String]

    /// Whether a raw file id is a known indexed file asset.
    func containsFileAsset(id: String) async -> Bool

    /// Bonus videos attached to one proven catalog or explicit folder owner.
    func extras(ownerID: String) async -> [MediaExtra]

    /// One separately inventoried bonus video addressed by its ordinary `f:` id.
    func extra(fileID: String) async -> MediaExtra?

    /// `nil` for a normal asset, otherwise the extra's resume policy.
    func extraResumeBehavior(fileID: String) async -> Bool?
}

/// The concrete SQLite-backed store is the production witness. Its methods are
/// synchronous actor-isolated reads, which satisfy the `async` requirements when
/// the store is used through `any ShareCatalogReading`.
extension ShareCatalogStore: ShareCatalogReading {}

public extension ShareCatalogReading {
    /// Default: no searchable cast.
    func itemsWithPerson(id personID: String?, name: String, limit: Int) async -> [MediaItem] { [] }

    func extras(ownerID: String) async -> [MediaExtra] { [] }
    func extra(fileID: String) async -> MediaExtra? { nil }
    func extraResumeBehavior(fileID: String) async -> Bool? { nil }
}
