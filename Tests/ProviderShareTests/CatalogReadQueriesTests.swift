import XCTest
import CoreModels
import MetadataKit
@testable import ProviderShare

/// Direct tests for the Batch-17 extraction out of `ShareCatalogStore`:
/// `CatalogReadQueries` — the pure, transaction-free read/query composition +
/// `MediaItem` building over one actor-confined `CatalogConnection`. The
/// whole-behavior net is the `ProviderShareTests` suite (the store facade forwards
/// its public read API here verbatim after `ensureOpen()`); these prove the
/// extracted read mechanics in isolation under one serialized connection, without
/// the store actor, and pin the shared `LocalMetadataPresence` memo contract.
final class CatalogReadQueriesTests: XCTestCase {
    private func openConnection() -> (CatalogConnection, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readq-\(UUID().uuidString).sqlite")
        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        return (conn, url)
    }

    private func makeQueries(
        _ conn: CatalogConnection,
        normalizedReady: Bool = true,
        presence: LocalMetadataPresence = LocalMetadataPresence()
    ) -> CatalogReadQueries {
        CatalogReadQueries(
            connection: conn,
            normalizedMetadataReady: normalizedReady,
            metadataConfig: MetadataEnrichmentConfig(),
            localMetadataPresence: presence
        )
    }

    private func seedMovie(_ conn: CatalogConnection, relPath: String, title: String, firstSeen: Double = 1, movieKey: String? = nil) {
        let key = movieKey ?? title.lowercased()
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, year, movie_key)
            VALUES('\(relPath)', 'base', 10, 0, \(firstSeen), 1,
              'movie', 'movies', '\(title)', '\(title.lowercased())', 2020, '\(key)');
            """))
    }

    private func seedEpisode(_ conn: CatalogConnection, relPath: String, seriesKey: String, seriesTitle: String, season: Int, episode: Int, firstSeen: Double = 1) {
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, series_title, series_key, season, episode)
            VALUES('\(relPath)', 'base', 10, 0, \(firstSeen), 1,
              'episode', 'tv', 'Ep \(episode)', 'ep \(episode)', '\(seriesTitle)',
              '\(seriesKey)', \(season), \(episode));
            """))
    }


    // MARK: - Recently Added ordering

    /// Seeds a movie with explicit discovery and file-modification times.
    private func seedMovieTimed(
        _ conn: CatalogConnection,
        relPath: String,
        title: String,
        firstSeen: Double,
        modified: Double
    ) {
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, year, movie_key)
            VALUES('\(relPath)', 'base', 10, \(modified), \(firstSeen), 1,
              'movie', 'movies', '\(title)', '\(title.lowercased())', 2020, '\(title.lowercased())');
            """))
    }

    /// A film discovered now comes first even though its file is decades old.
    /// Recently Added means recently added to *this library*, so an old release
    /// downloaded today must still lead — the newest discovery bucket wins outright
    /// and the file's own mtime never gets a say across buckets.
    func testANewlyDiscoveredItemLeadsRegardlessOfFileAge() {
        let (conn, _) = openConnection()
        let now = Date().timeIntervalSince1970
        seedMovieTimed(conn, relPath: "M/Old.mkv", title: "Old Film",
                       firstSeen: now, modified: now - 40 * 365 * 86_400)
        seedMovieTimed(conn, relPath: "M/Recent.mkv", title: "Recent Film",
                       firstSeen: now - 7 * 86_400, modified: now - 86_400)

        let titles = makeQueries(conn).latest(limit: 10).map(\.title)
        XCTAssertEqual(titles.first, "Old Film")
    }

    /// The case that broke on device. A rebuilt catalog stamps every row with
    /// essentially the same `first_seen_at`, differing only by the milliseconds it
    /// took the walk to reach each one — which encodes directory order, not
    /// recency. Bucketing collapses that, leaving the file's own mtime to order
    /// them, so the genuinely newest files surface instead of whichever the walk
    /// happened to reach last.
    func testAfterACatalogRebuildFileTimeDecidesTheOrder() {
        let (conn, _) = openConnection()
        let rebuild = Date().timeIntervalSince1970
        // Discovered in walk order, which is unrelated to when they arrived.
        seedMovieTimed(conn, relPath: "M/A.mkv", title: "Alpha",
                       firstSeen: rebuild + 0.001, modified: rebuild - 300 * 86_400)
        seedMovieTimed(conn, relPath: "M/B.mkv", title: "Bravo",
                       firstSeen: rebuild + 0.002, modified: rebuild - 86_400)
        seedMovieTimed(conn, relPath: "M/C.mkv", title: "Charlie",
                       firstSeen: rebuild + 0.003, modified: rebuild - 100 * 86_400)

        let titles = makeQueries(conn).latest(limit: 10).map(\.title)
        XCTAssertEqual(titles, ["Bravo", "Charlie", "Alpha"])
    }

    /// Identical on every read. Ordering that depends on the order SQLite returns
    /// rows in makes Recently Added visibly reshuffle whenever Home reloads.
    func testOrderingIsStableAcrossRepeatedReads() {
        let (conn, _) = openConnection()
        let now = Date().timeIntervalSince1970
        for index in 0..<12 {
            seedMovieTimed(conn, relPath: "M/\(index).mkv", title: "Film \(index)",
                           firstSeen: now, modified: now)
        }
        let queries = makeQueries(conn)
        let first = queries.latest(limit: 12).map(\.id)
        XCTAssertEqual(first, queries.latest(limit: 12).map(\.id))
        XCTAssertEqual(first.count, 12)
    }

    /// Series are ranked the same way, and against movies, so one merged row can
    /// hold both without either kind clumping.
    func testSeriesAndMoviesInterleaveByTheSameRule() {
        let (conn, _) = openConnection()
        let now = Date().timeIntervalSince1970
        seedMovieTimed(conn, relPath: "M/Old.mkv", title: "Old Movie",
                       firstSeen: now - 30 * 86_400, modified: now - 30 * 86_400)
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, series_title, series_key, season, episode)
            VALUES('TV/S/E1.mkv', 'base', 10, \(now), \(now), 1,
              'episode', 'tv', 'Ep 1', 'ep 1', 'New Show', 'new-show', 1, 1);
            """))

        let titles = makeQueries(conn).latest(limit: 10).map(\.title)
        XCTAssertEqual(titles.first, "New Show", "the newer discovery leads regardless of kind")
    }

    // MARK: - empty / counts

    func testEmptyCatalog() {
        let (conn, _) = openConnection()
        let q = makeQueries(conn)
        XCTAssertTrue(q.isEmpty())
        XCTAssertEqual(q.movieCount(), 0)
        XCTAssertEqual(q.seriesCount(in: .tv), 0)
        let counts = q.libraryCounts()
        XCTAssertEqual(counts.movies, 0)
        XCTAssertEqual(counts.tvSeries, 0)
        XCTAssertEqual(counts.animeSeries, 0)
    }

    func testMovieAndSeriesCounts() {
        let (conn, _) = openConnection()
        seedMovie(conn, relPath: "Movies/A.mkv", title: "Alpha")
        seedMovie(conn, relPath: "Movies/B.mkv", title: "Beta")
        seedEpisode(conn, relPath: "TV/Show/S01E01.mkv", seriesKey: "show", seriesTitle: "Show", season: 1, episode: 1)
        seedEpisode(conn, relPath: "TV/Show/S01E02.mkv", seriesKey: "show", seriesTitle: "Show", season: 1, episode: 2)
        let q = makeQueries(conn)
        XCTAssertFalse(q.isEmpty())
        XCTAssertEqual(q.movieCount(), 2)
        XCTAssertEqual(q.seriesCount(in: .tv), 1)
        let counts = q.libraryCounts()
        XCTAssertEqual(counts.movies, 2)
        XCTAssertEqual(counts.tvSeries, 1)
    }

    // MARK: - item building

    func testMoviesGridAndItemLookup() {
        let (conn, _) = openConnection()
        seedMovie(conn, relPath: "Movies/Alpha.mkv", title: "Alpha")
        let q = makeQueries(conn)
        let movies = q.movies(offset: 0, limit: 50)
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(movies.first?.title, "Alpha")
        // Resolve the same movie by its file id and its logical movie id.
        let byFile = q.item(id: ShareCatalogID.file("Movies/Alpha.mkv"))
        XCTAssertNotNil(byFile)
        let byMovie = q.item(id: movies[0].id)
        XCTAssertNotNil(byMovie)
    }

    func testSeriesSeasonsAndEpisodes() {
        let (conn, _) = openConnection()
        seedEpisode(conn, relPath: "TV/Show/S01E01.mkv", seriesKey: "show", seriesTitle: "Show", season: 1, episode: 1)
        seedEpisode(conn, relPath: "TV/Show/S01E02.mkv", seriesKey: "show", seriesTitle: "Show", season: 1, episode: 2)
        let q = makeQueries(conn)
        let series = q.series(in: .tv, offset: 0, limit: 50)
        XCTAssertEqual(series.count, 1)
        let seasons = q.seasons(seriesKey: "show")
        XCTAssertEqual(seasons.count, 1)
        let eps = q.episodes(seriesKey: "show", season: 1)
        XCTAssertEqual(eps.count, 2)
    }

    func testSearchAndLatest() {
        let (conn, _) = openConnection()
        seedMovie(conn, relPath: "Movies/Alpha.mkv", title: "Alpha", firstSeen: 10)
        seedEpisode(conn, relPath: "TV/Show/S01E01.mkv", seriesKey: "show", seriesTitle: "Beta Show", season: 1, episode: 1, firstSeen: 20)
        let q = makeQueries(conn)
        XCTAssertFalse(q.latest(limit: 10).isEmpty)
        XCTAssertEqual(q.search(query: "Alpha", limit: 10).first?.title, "Alpha")
        XCTAssertFalse(q.search(query: "Beta", limit: 10).isEmpty)
    }

    // MARK: - canonical id folding / asset existence

    func testCanonicalItemIDFoldsMovieFileToLogicalMovie() {
        let (conn, _) = openConnection()
        seedMovie(conn, relPath: "Movies/Alpha.mkv", title: "Alpha")
        let q = makeQueries(conn)
        let canonical = q.canonicalItemID(ShareCatalogID.file("Movies/Alpha.mkv"))
        XCTAssertTrue(canonical.hasPrefix("movie:"), "expected a logical movie id, got \(canonical)")
        XCTAssertTrue(q.containsFileAsset(id: ShareCatalogID.file("Movies/Alpha.mkv")))
        XCTAssertFalse(q.containsFileAsset(id: ShareCatalogID.file("Movies/Missing.mkv")))
    }

    // MARK: - LocalMetadataPresence memo contract

    func testLocalMetadataPresenceMemoLazilyPopulatesAndIsShared() {
        let (conn, _) = openConnection()
        seedMovie(conn, relPath: "Movies/Alpha.mkv", title: "Alpha")
        let presence = LocalMetadataPresence()
        XCTAssertNil(presence.cached, "memo starts unresolved")
        let q = makeQueries(conn, presence: presence)
        // A read that overlays local metadata resolves the shared memo box exactly once.
        _ = q.movies(offset: 0, limit: 50)
        XCTAssertEqual(presence.cached, false, "no local metadata rows exist → memo resolves to false")
        // Invalidation (as the store's write paths do) resets the shared box.
        presence.cached = nil
        _ = q.movies(offset: 0, limit: 50)
        XCTAssertEqual(presence.cached, false)
    }
}
