import XCTest
@testable import ProviderShare
import CoreModels
import SQLite3

/// Coverage for the SQLite-backed share catalog — the index that makes a share's
/// Recently Added / Search / Movies-TV-Anime libraries work without a live SMB
/// walk. These are the on-device questions a server never had to answer:
/// does "date added" stay first-discovery across re-scans, does the index survive
/// a relaunch, and do the id shapes resolve back to rich items?
final class ShareCatalogStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func movie(_ path: String, title: String, year: Int?) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .movie, library: .movies,
                     title: title, year: year, seriesTitle: nil, seriesKey: nil, season: nil, episode: nil)
    }

    private func episode(_ path: String, series: String, season: Int, episode: Int, library: CatalogLibrary = .tv) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .episode, library: library,
                     title: "Episode \(episode)", year: nil,
                     seriesTitle: series, seriesKey: ShareCatalogID.seriesKey(fromTitle: series),
                     season: season, episode: episode)
    }

    private func catalogURL(accountKey: String, in directory: URL) -> URL {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(accountKey.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in accountKey.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appendingPathComponent(
            "share-catalog-\(mapped.prefix(80))-\(String(hash, radix: 16)).sqlite"
        )
    }

    private func sqliteInt(at url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 10)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 11)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 12)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func sqliteText(at url: URL, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 13)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 14)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func createLegacyCatalog(
        in directory: URL,
        withPartialNormalizedTables: Bool = false
    ) throws -> URL {
        let url = catalogURL(accountKey: "legacy", in: directory)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE assets(
          rel_path TEXT PRIMARY KEY, basename TEXT NOT NULL, size INTEGER NOT NULL,
          modified_at REAL NOT NULL, first_seen_at REAL NOT NULL, last_scan INTEGER NOT NULL,
          kind TEXT NOT NULL, library TEXT NOT NULL, title TEXT NOT NULL,
          sort_title TEXT NOT NULL, year INTEGER, series_title TEXT, series_key TEXT,
          season INTEGER, episode INTEGER
        );
        CREATE TABLE enrichment(
          item_id TEXT PRIMARY KEY, provider_ids_json TEXT, overview TEXT,
          genres_json TEXT, runtime REAL, poster_url TEXT, backdrop_url TEXT,
          logo_url TEXT, enriched_at REAL NOT NULL, enrich_version INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, title TEXT
        );
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO assets VALUES
          ('Movies/Rich.mkv','Rich.mkv',100,10,10,1,'movie','movies','Rich','rich',2001,NULL,NULL,NULL,NULL),
          ('Movies/Sparse.mkv','Sparse.mkv',100,20,20,1,'movie','movies','Sparse','sparse',2002,NULL,NULL,NULL,NULL),
          ('Movies/Exhausted.mkv','Exhausted.mkv',100,30,30,1,'movie','movies','Exhausted','exhausted',2003,NULL,NULL,NULL,NULL),
          ('Movies/Retry.mkv','Retry.mkv',100,40,40,1,'movie','movies','Retry','retry',2004,NULL,NULL,NULL,NULL),
          ('TV/Anime Show/S01E01.mkv','S01E01.mkv',100,50,50,1,'episode','tv','Episode 1','episode 1',NULL,'Anime Show','anime-show',1,1);
        INSERT INTO enrichment VALUES
          ('f:Movies/Rich.mkv','{"Tvdb":"42","Imdb":"tt0042","AniList":"84"}',
           'Rich overview','["Drama","Mystery"]',7200,
           'https://example.com/poster.jpg','https://example.com/backdrop.jpg',
           'https://example.com/logo.png',1234,7,0,'Rich Show'),
          ('f:Movies/Sparse.mkv',NULL,'Sparse overview',NULL,NULL,NULL,NULL,NULL,2345,7,0,NULL),
          ('f:Movies/Exhausted.mkv',NULL,NULL,NULL,NULL,NULL,NULL,NULL,3456,7,3,NULL),
          ('f:Movies/Retry.mkv',NULL,NULL,NULL,NULL,NULL,NULL,NULL,4567,7,2,NULL),
          ('series:anime-show','{"AniList":"100","Tvdb":"200"}',NULL,NULL,NULL,NULL,NULL,NULL,5678,7,0,'Anime Show');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "ShareCatalogStoreTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        if withPartialNormalizedTables {
            let partialSQL = """
            CREATE TABLE metadata_values(
              item_id TEXT NOT NULL, field TEXT NOT NULL, source TEXT NOT NULL,
              value_json TEXT NOT NULL, source_url TEXT, source_revision TEXT,
              refreshed_at REAL, expires_at REAL,
              PRIMARY KEY(item_id, field, source)
            );
            CREATE TABLE metadata_enrichment_state(
              item_id TEXT PRIMARY KEY, local_version INTEGER, external_version INTEGER,
              local_attempts INTEGER NOT NULL DEFAULT 0,
              external_attempts INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO metadata_values VALUES
              ('f:Movies/Rich.mkv','overview','futureProvider','"Rich overview"',
               'https://metadata.example/rich',NULL,9999,NULL),
              ('f:Movies/Rich.mkv','posterURL','futureProvider','{',
               NULL,NULL,9999,NULL);
            INSERT INTO metadata_enrichment_state VALUES
              ('f:Movies/Rich.mkv',NULL,NULL,0,0);
            """
            guard sqlite3_exec(db, partialSQL, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "ShareCatalogStoreTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }
        return url
    }

    private struct MigrationState {
        var userVersion: Int
        var metadataValueCount: Int
        var enrichmentStateCount: Int
        var richLegacyValueCount: Int
        var enrichedAt: Double
        var enrichVersion: Int
        var attempts: Int
        var externalVersion: Int
        var externalAttempts: Int
    }

    private func queryMigrationState(at url: URL) throws -> MigrationState {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 3)
        }
        defer { sqlite3_close(db) }

        func integer(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT e.enriched_at, e.enrich_version, e.attempts,
               s.external_version, s.external_attempts
        FROM enrichment e
        JOIN metadata_enrichment_state s ON s.item_id=e.item_id
        WHERE e.item_id='f:Movies/Rich.mkv';
        """, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            throw NSError(domain: "ShareCatalogStoreTests", code: 4)
        }
        defer { sqlite3_finalize(stmt) }
        return MigrationState(
            userVersion: integer("PRAGMA user_version;"),
            metadataValueCount: integer("SELECT COUNT(*) FROM metadata_values;"),
            enrichmentStateCount: integer("SELECT COUNT(*) FROM metadata_enrichment_state;"),
            richLegacyValueCount: integer("""
                SELECT COUNT(*) FROM metadata_values
                WHERE item_id='f:Movies/Rich.mkv' AND source='legacyUnknown';
                """),
            enrichedAt: sqlite3_column_double(stmt, 0),
            enrichVersion: Int(sqlite3_column_int64(stmt, 1)),
            attempts: Int(sqlite3_column_int64(stmt, 2)),
            externalVersion: Int(sqlite3_column_int64(stmt, 3)),
            externalAttempts: Int(sqlite3_column_int64(stmt, 4))
        )
    }

    func testLegacyCatalogMigrationPreservesMetadataAndPendingState() async throws {
        let directory = tempDir()
        let url = try createLegacyCatalog(in: directory)
        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)

        let loadedRich = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loadedRich)
        XCTAssertEqual(rich.title, "Rich Show")
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.genres, ["Drama", "Mystery"])
        XCTAssertEqual(rich.runtime, 7_200)
        XCTAssertEqual(rich.providerIDs, ["Tvdb": "42", "Imdb": "tt0042", "AniList": "84"])
        XCTAssertEqual(rich.metadataProvenance[.overview]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.providerID("Tvdb")]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.posterURL]?.source, .legacyUnknown)
        let anime = await store.item(id: "series:anime-show")
        XCTAssertEqual(anime?.providerIDs, ["AniList": "100", "Tvdb": "200"])
        XCTAssertEqual(
            anime?.metadataProvenance[.providerID("AniList")]?.source,
            .legacyUnknown
        )

        let pending = await store.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(pending.map(\.itemID), ["f:Movies/Retry.mkv"])

        let state = try queryMigrationState(at: url)
        // v2 adds the Step 3 NFO/explicit-id sidecar inventory schema; the legacy
        // catalog's Step 2 normalized rows/state must still migrate/read exactly
        // as before.
        XCTAssertEqual(state.userVersion, 2)
        XCTAssertEqual(state.metadataValueCount, 14)
        XCTAssertEqual(state.enrichmentStateCount, 5)
        XCTAssertEqual(state.richLegacyValueCount, 10)
        XCTAssertEqual(state.enrichedAt, 1_234)
        XCTAssertEqual(state.enrichVersion, 7)
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.externalVersion, 7)
        XCTAssertEqual(state.externalAttempts, 0)

        let reopened = ShareCatalogStore(accountKey: "legacy", directory: directory)
        let reopenedPending = await reopened.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(reopenedPending.map(\.itemID), [
            "f:Movies/Retry.mkv"
        ])
        XCTAssertEqual(try queryMigrationState(at: url).userVersion, 2)
    }

    func testPartiallyMigratedCatalogDecodesValidProvenanceAndInfersMissingEntries() async throws {
        let directory = tempDir()
        _ = try createLegacyCatalog(in: directory, withPartialNormalizedTables: true)
        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)

        let loadedRich = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loadedRich)
        XCTAssertEqual(
            rich.metadataProvenance[.overview]?.source,
            MetadataSource(rawValue: "futureProvider")
        )
        XCTAssertEqual(rich.metadataProvenance[.posterURL]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.providerID("Imdb")]?.source, .legacyUnknown)
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.posterURL, URL(string: "https://example.com/poster.jpg"))
    }

    func testFailedNormalizedMigrationKeepsFlatCatalogReadableAndRejectsWrites() async throws {
        let directory = tempDir()
        let url = try createLegacyCatalog(in: directory)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE metadata_values(item_id TEXT PRIMARY KEY);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)
        let loaded = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loaded)
        XCTAssertEqual(rich.title, "Rich Show")
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.providerIDs["Tvdb"], "42")
        XCTAssertEqual(rich.metadataProvenance[.overview]?.source, .legacyUnknown)
        let pending = await store.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(pending.map(\.itemID), ["f:Movies/Retry.mkv"])

        let writeAccepted = await store.saveEnrichment(
            itemID: "f:Movies/Rich.mkv",
            .init(overview: "Must not split the projection"),
            version: 7
        )
        XCTAssertFalse(writeAccepted)
        let unchanged = await store.item(id: "f:Movies/Rich.mkv")
        XCTAssertEqual(unchanged?.overview, "Rich overview")
    }

    func testSourcedEnrichmentDualWritesAndRoundTripsExactAttribution() async throws {
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: "sourced", directory: directory)
        await store.upsert([
            movie("Movies/Sourced (2020).mkv", title: "Sourced", year: 2020)
        ], scanID: 1)
        let sourceURL = try XCTUnwrap(URL(string: "https://metadata.example/sourced"))
        let saved = await store.saveEnrichment(
            itemID: "f:Movies/Sourced (2020).mkv",
            .sourced(
                providerIDs: [
                    "Tvdb": SourcedValue(
                        value: "900",
                        source: .tvdb,
                        sourceURL: sourceURL
                    ),
                    "AniList": SourcedValue(
                        value: "901",
                        source: .anilist,
                        sourceURL: URL(string: "https://anilist.co/anime/901")
                    )
                ],
                overview: SourcedValue(
                    value: "Exact overview",
                    source: .tvmaze,
                    sourceURL: sourceURL
                ),
                posterURL: SourcedValue(
                    value: try XCTUnwrap(URL(string: "https://example.com/sourced.jpg")),
                    source: .tmdb,
                    sourceURL: sourceURL
                ),
                title: SourcedValue(
                    value: "Sourced Show",
                    source: .tvdb,
                    sourceURL: sourceURL
                )
            ),
            version: 7,
            now: Date(timeIntervalSince1970: 8_000)
        )
        XCTAssertTrue(saved)

        let reopened = ShareCatalogStore(accountKey: "sourced", directory: directory)
        let loaded = await reopened.item(id: "f:Movies/Sourced (2020).mkv")
        let item = try XCTUnwrap(loaded)
        XCTAssertEqual(item.title, "Sourced Show")
        XCTAssertEqual(item.overview, "Exact overview")
        XCTAssertEqual(item.providerIDs["Tvdb"], "900")
        XCTAssertEqual(item.metadataProvenance[.title]?.source, .tvdb)
        XCTAssertEqual(item.metadataProvenance[.overview]?.source, .tvmaze)
        XCTAssertEqual(item.metadataProvenance[.posterURL]?.source, .tmdb)
        XCTAssertEqual(item.metadataProvenance[.providerID("AniList")]?.source, .anilist)
        XCTAssertEqual(item.metadataProvenance[.title]?.sourceURL, sourceURL)
    }

    func testAnimeClassificationCommitsWithFlatAndNormalizedEnrichment() async throws {
        let accountKey = "atomic-anime"
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let series = "Atomic Anime"
        let seriesKey = ShareCatalogID.seriesKey(fromTitle: series)
        let seriesID = ShareCatalogID.series(seriesKey)
        await store.upsert([
            episode("TV/Atomic Anime/S01E01.mkv", series: series, season: 1, episode: 1)
        ], scanID: 1)

        let saved = await store.saveEnrichment(
            itemID: seriesID,
            .init(providerIDs: ["AniList": "100"]),
            version: 7
        )
        XCTAssertTrue(saved)
        let tvSeries = await store.series(in: .tv, offset: 0, limit: 10)
        let animeSeries = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertTrue(tvSeries.isEmpty)
        XCTAssertEqual(animeSeries.count, 1)

        let url = catalogURL(accountKey: accountKey, in: directory)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets
            WHERE series_key='\(seriesKey)' AND library='anime';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM enrichment WHERE item_id='\(seriesID)';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM metadata_values WHERE item_id='\(seriesID)';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM metadata_enrichment_state WHERE item_id='\(seriesID)';
            """), 1)
    }

    func testStrongIDReconciliationDeletesLoserFromEveryMetadataTable() async throws {
        let accountKey = "atomic-merge"
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let loserKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinder")
        let canonicalKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinders")
        await store.upsert([
            episode("TV/Peaky Blinder/S01E01.mkv", series: "Peaky Blinder", season: 1, episode: 1),
            episode("TV/Peaky Blinders/S01E01.mkv", series: "Peaky Blinders", season: 1, episode: 1)
        ], scanID: 1)

        let loserSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(loserKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        let canonicalSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(canonicalKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        XCTAssertTrue(loserSaved)
        XCTAssertTrue(canonicalSaved)

        let url = catalogURL(accountKey: accountKey, in: directory)
        let loserID = ShareCatalogID.series(loserKey)
        let canonicalID = ShareCatalogID.series(canonicalKey)
        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets WHERE series_key='\(canonicalKey)';
            """), 2)
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT canonical_key FROM series_merge WHERE alias_key='\(loserKey)';
            """), canonicalKey)
        for table in ["enrichment", "metadata_values", "metadata_enrichment_state"] {
            XCTAssertEqual(try sqliteInt(at: url, """
                SELECT COUNT(*) FROM \(table) WHERE item_id='\(loserID)';
                """), 0, "\(table) must not retain loser rows")
            XCTAssertGreaterThan(try sqliteInt(at: url, """
                SELECT COUNT(*) FROM \(table) WHERE item_id='\(canonicalID)';
                """), 0, "\(table) must retain the canonical row")
        }
    }

    func testDerivedMutationFailureRollsBackProjectionMetadataAssetsAndAliases() async throws {
        let accountKey = "atomic-rollback"
        let directory = tempDir()
        let initialStore = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let loserKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinder")
        let canonicalKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinders")
        let loserID = ShareCatalogID.series(loserKey)
        await initialStore.upsert([
            episode("TV/Peaky Blinder/S01E01.mkv", series: "Peaky Blinder", season: 1, episode: 1),
            episode("TV/Peaky Blinders/S01E01.mkv", series: "Peaky Blinders", season: 1, episode: 1)
        ], scanID: 1)
        let canonicalSaved = await initialStore.saveEnrichment(
            itemID: ShareCatalogID.series(canonicalKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        let loserSaved = await initialStore.saveEnrichment(
            itemID: loserID,
            .init(providerIDs: ["Tvdb": "999"], title: "Peaky Blinder"),
            version: 7
        )
        XCTAssertTrue(canonicalSaved)
        XCTAssertTrue(loserSaved)

        let failingStore = ShareCatalogStore(
            accountKey: accountKey,
            directory: directory,
            enrichmentSaveFailurePoint: .afterDerivedCatalogMutations
        )
        let saved = await failingStore.saveEnrichment(
            itemID: loserID,
            .init(
                providerIDs: ["Tvdb": "270261", "AniList": "100"],
                title: "Peaky Blinders"
            ),
            version: 8
        )
        XCTAssertFalse(saved)

        let url = catalogURL(accountKey: accountKey, in: directory)
        let tvSeries = await failingStore.series(in: .tv, offset: 0, limit: 10)
        let animeSeries = await failingStore.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(tvSeries.count, 2)
        XCTAssertTrue(animeSeries.isEmpty)
        XCTAssertEqual(try sqliteInt(at: url, "SELECT COUNT(*) FROM series_merge;"), 0)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets WHERE series_key='\(loserKey)' AND library='tv';
            """), 1)
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT provider_ids_json FROM enrichment WHERE item_id='\(loserID)';
            """), "{\"Tvdb\":\"999\"}")
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT value_json FROM metadata_values
            WHERE item_id='\(loserID)' AND field='providerID.tvdb';
            """), "\"999\"")
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT external_version FROM metadata_enrichment_state WHERE item_id='\(loserID)';
            """), 7)
    }

    /// A large first-time regroup may take a few hundred milliseconds overall,
    /// but must yield the catalog actor so a Movies-grid page can complete without
    /// waiting for the whole regroup.
    func testLargeMovieRegroupDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf", directory: tempDir())
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            let title = "Movie \(index / 2)"
            let year = 2000 + (index % 2)
            return CatalogAsset(
                relPath: "Movies/\(title) (\(year)) \(index).mkv",
                basename: "\(title) (\(year)) \(index).mkv",
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: title, year: year, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: ShareCatalogID.movieKey(fromTitle: title, year: year),
                movieTitleKey: ShareCatalogID.seriesKey(fromTitle: title)
            )
        }
        await store.upsert(assets, scanID: 1)

        let clock = ContinuousClock()
        let rebuildStart = clock.now
        let rebuild = Task { await store.rebuildMovieGroups() }
        await Task.yield()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await rebuild.value
        let rebuildDuration = rebuildStart.duration(to: clock.now)
        XCTAssertLessThan(
            browseDuration,
            .milliseconds(100),
            "browse reads must interleave with a large end-of-scan regroup (regroup: \(rebuildDuration))"
        )
    }

    /// One unusually large directory must not hold the catalog actor for its
    /// entire insert; the chunked upsert yields between bounded transactions.
    func testLargeDirectoryUpsertDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf-upsert", directory: tempDir())
        await store.upsert([movie("Movies/Existing (2000).mkv", title: "Existing", year: 2000)], scanID: 1)
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            movie("Movies/New \(index) (2020).mkv", title: "New \(index)", year: 2020)
        }

        let upsert = Task { await store.upsert(assets, scanID: 2) }
        await Task.yield()
        let clock = ContinuousClock()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await upsert.value

        XCTAssertLessThan(
            browseDuration,
            .milliseconds(100),
            "browse reads must interleave with a giant directory upsert"
        )
    }

    func testEmptyUntilPopulated() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let empty = await store.isEmpty()
        XCTAssertTrue(empty)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 0)
        XCTAssertEqual(counts.tvSeries, 0)
        XCTAssertEqual(counts.animeSeries, 0)
        let latest = await store.latest(limit: 10)
        XCTAssertTrue(latest.isEmpty)
    }

    func testLatestOrdersByFirstSeenDescending() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "newest first-seen should lead Recently Added")
    }

    func testFirstSeenPreservedAcrossReUpsert() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        // Re-scan sees A again at t3 — its first_seen must NOT jump to t3.
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 2, now: t3)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "a re-seen file keeps its original date added")
    }

    func testSeriesGroupingSeasonsAndEpisodes() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "Breaking Bad")
        await store.upsert([
            episode("TV/Breaking Bad/S01/E01.mkv", series: "Breaking Bad", season: 1, episode: 1),
            episode("TV/Breaking Bad/S01/E02.mkv", series: "Breaking Bad", season: 1, episode: 2),
            episode("TV/Breaking Bad/S02/E01.mkv", series: "Breaking Bad", season: 2, episode: 1),
        ], scanID: 1)

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.kind, .series)
        XCTAssertEqual(series.first?.id, ShareCatalogID.series(key))

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2])

        let s1 = await store.episodes(seriesKey: key, season: 1)
        XCTAssertEqual(s1.map(\.episodeNumber), [1, 2], "episodes in episode order")
        XCTAssertTrue(s1.allSatisfy { $0.kind == .episode && $0.parentTitle == "Breaking Bad" })
    }

    /// Regression: normalized-equivalent episode titles/library classifications
    /// must not emit duplicate season tabs with identical ids (which makes tvOS
    /// focus collapse onto only one of the visually duplicated buttons).
    func testSeasonsDeduplicateVariantSeriesMetadataBySeasonNumber() async {
        let store = ShareCatalogStore(accountKey: "korra", directory: tempDir())
        let canonical = "The Legend of Korra"
        let key = ShareCatalogID.seriesKey(fromTitle: canonical)
        let variants: [(season: Int, title: String, library: CatalogLibrary)] = [
            (1, canonical, .tv),
            (2, canonical, .tv),
            (3, "The.Legend.of.Korra", .tv),
            (3, canonical, .anime),
            (4, "The.Legend.of.Korra", .tv),
            (4, canonical, .anime),
        ]
        let assets = variants.map { value in
            CatalogAsset(
                relPath: "TV/Korra/S\(value.season)/E01-\(value.title)-\(value.library.rawValue).mkv",
                basename: "E01.mkv", size: 1_000, modifiedAt: Date(),
                kind: .episode, library: value.library,
                title: "Episode 1", year: nil,
                seriesTitle: value.title, seriesKey: key,
                season: value.season, episode: 1
            )
        }
        await store.upsert(assets, scanID: 1)

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2, 3, 4])
        XCTAssertEqual(Set(seasons.map(\.id)).count, 4, "season ids must be unique for stable focus")
        XCTAssertTrue(seasons.allSatisfy { $0.parentTitle == canonical })
        XCTAssertTrue(seasons.allSatisfy { $0.libraryID == ShareCatalogID.animeLibrary })
    }

    func testLibrarySortIgnoresLeadingTheAndUsesSeriesTitle() async {
        let store = ShareCatalogStore(accountKey: "sort", directory: tempDir())
        await store.upsert([
            movie("Movies/Zootopia (2016).mkv", title: "Zootopia", year: 2016),
            movie("Movies/The Batman (2022).mkv", title: "The Batman", year: 2022),
            movie("Movies/Avatar (2009).mkv", title: "Avatar", year: 2009),
            episode("TV/Yellowstone/S01E01.mkv", series: "Yellowstone", season: 1, episode: 1),
            // Episode titles intentionally sort differently; the grid must use the
            // SERIES title, not "Zulu"/"Alpha".
            CatalogAsset(
                relPath: "TV/The Bear/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Zulu", year: nil, seriesTitle: "The Bear",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "The Bear"),
                season: 1, episode: 1
            ),
            CatalogAsset(
                relPath: "TV/Andor/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Alpha", year: nil, seriesTitle: "Andor",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "Andor"),
                season: 1, episode: 1
            ),
        ], scanID: 1)

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Avatar", "The Batman", "Zootopia"])

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.map(\.title), ["Andor", "The Bear", "Yellowstone"])
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "Theodore"), "theodore")
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "  THE   Thing  "), "thing")
    }

    func testAnimeAndTvLibrariesAreSeparate() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/Show/E01.mkv", series: "Some Show", season: 1, episode: 1, library: .tv),
            episode("Anime/Naruto/E01.mkv", series: "Naruto", season: 1, episode: 1, library: .anime),
        ], scanID: 1)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.tvSeries, 1)
        XCTAssertEqual(counts.animeSeries, 1)
        let tv = await store.series(in: .tv, offset: 0, limit: 10)
        let anime = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(tv.map(\.title), ["Some Show"])
        XCTAssertEqual(anime.map(\.title), ["Naruto"])
    }

    func testSearchFindsMoviesAndSeries() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/The Matrix (1999).mkv", title: "The Matrix", year: 1999),
            episode("TV/Matrix Reloaded Show/E01.mkv", series: "Matrix Reloaded Show", season: 1, episode: 1),
            movie("Movies/Unrelated (2001).mkv", title: "Unrelated", year: 2001),
        ], scanID: 1)
        let hits = await store.search(query: "matrix", limit: 20)
        let titles = Set(hits.map(\.title))
        XCTAssertTrue(titles.contains("The Matrix"))
        XCTAssertTrue(titles.contains("Matrix Reloaded Show"))
        XCTAssertFalse(titles.contains("Unrelated"))

        let fullTitleHits = await store.search(query: "The Matrix", limit: 20)
        XCTAssertEqual(fullTitleHits.map(\.title), ["The Matrix"])
    }

    func testItemResolvesEveryIdShape() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "The Show")
        await store.upsert([
            movie("Movies/Film (2020).mkv", title: "Film", year: 2020),
            episode("TV/The Show/S01/E03.mkv", series: "The Show", season: 1, episode: 3),
        ], scanID: 1)

        let movieItem = await store.item(id: ShareCatalogID.file("Movies/Film (2020).mkv"))
        XCTAssertEqual(movieItem?.kind, .movie)
        XCTAssertEqual(movieItem?.productionYear, 2020)

        let seriesItem = await store.item(id: ShareCatalogID.series(key))
        XCTAssertEqual(seriesItem?.kind, .series)
        XCTAssertEqual(seriesItem?.title, "The Show")

        let seasonItem = await store.item(id: ShareCatalogID.season(key, 1))
        XCTAssertEqual(seasonItem?.kind, .season)
        XCTAssertEqual(seasonItem?.seasonNumber, 1)

        let episodeItem = await store.item(id: ShareCatalogID.file("TV/The Show/S01/E03.mkv"))
        XCTAssertEqual(episodeItem?.kind, .episode)
        XCTAssertEqual(episodeItem?.episodeNumber, 3)
        XCTAssertEqual(episodeItem?.seriesID, ShareCatalogID.series(key))

        let unknown = await store.item(id: "share:root")
        XCTAssertNil(unknown, "raw file-tree ids resolve via the browser, not the catalog")
    }

    func testPruneRemovesAssetsNotSeenInLatestScan() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000),
            movie("Movies/Gone (2001).mkv", title: "Gone", year: 2001),
        ], scanID: 1)
        // Next full scan only re-saw "Keep".
        await store.upsert([movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000)], scanID: 2)
        await store.pruneNotSeen(inScan: 2)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Keep"])
    }

    func testCatalogSurvivesRelaunch() async {
        let dir = tempDir()
        let live = ShareCatalogStore(accountKey: "acct", directory: dir)
        await live.upsert([movie("Movies/Persisted (2010).mkv", title: "Persisted", year: 2010)], scanID: 1)

        // Fresh store on the same dir == a relaunch (only the DB file remains).
        let reopened = ShareCatalogStore(accountKey: "acct", directory: dir)
        let movies = await reopened.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Persisted"])
    }

    func testSeasonIdRoundTripsWithColonInKey() {
        // seriesKey never contains a colon, but guard the decoder anyway.
        let key = "breaking-bad"
        let id = ShareCatalogID.season(key, 3)
        let decoded = ShareCatalogID.seasonComponents(forSeasonID: id)
        XCTAssertEqual(decoded?.seriesKey, key)
        XCTAssertEqual(decoded?.season, 3)
    }

    func testEpisodeSidecarAssociationRequiresEpisodeAssetKind() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let videoPath = "TV/Show/S01E01.mkv"
        let sidecar = ShareCatalogStore.PendingLocalMetadataFile(
            relPath: "TV/Show/S01E01.nfo",
            parentDir: "TV/Show",
            kind: .episodeStem,
            size: 100,
            associatedVideoRelPath: videoPath,
            processedItemID: nil,
            fingerprint: "etag:test",
            scanGenerationBound: false,
            status: "pending",
            attempts: 0
        )

        await store.upsert([movie(videoPath, title: "Reclassified", year: nil)], scanID: 1)
        var facts = await store.localMetadataAssociationFacts(for: sidecar)
        XCTAssertFalse(facts.associatedVideoExists)

        await store.upsert([
            episode(videoPath, series: "Show", season: 1, episode: 1),
        ], scanID: 2)
        facts = await store.localMetadataAssociationFacts(for: sidecar)
        XCTAssertTrue(facts.associatedVideoExists)
    }

    func testSeriesKeyNormalizesPunctuationAndCase() {
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Breaking Bad"),
                       ShareCatalogID.seriesKey(fromTitle: "breaking.bad"))
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Mr. Robot"), "mr-robot")
    }

    // MARK: - Reconciliation primitives

    func testLevenshtein() {
        XCTAssertEqual(ShareCatalogStore.levenshtein("peaky blinder", "peaky blinders"), 1)
        XCTAssertEqual(ShareCatalogStore.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(ShareCatalogStore.levenshtein("same", "same"), 0)
        XCTAssertEqual(ShareCatalogStore.levenshtein("", "abc"), 3)
    }

    func testTitlesNearlyIdentical() {
        // Typo / plural of one show.
        XCTAssertTrue(ShareCatalogStore.titlesNearlyIdentical("Peaky Blinder", "Peaky Blinders"))
        XCTAssertTrue(ShareCatalogStore.titlesNearlyIdentical("The Handmaids Tale", "The Handmaid's Tale"))
        // A digit difference is a deliberate distinction — never "nearly identical".
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("1883", "1923"))
        // Too short / too different.
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("Fargo", "Cargo"))
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("Lost", "Loki"))
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("The Office", "The Wire"))
    }

    func testResolveAliasFollowsChains() {
        let map = ["a": "b", "b": "c", "x": "y"]
        XCTAssertEqual(ShareCatalogStore.resolveAlias("a", in: map), "c")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("b", in: map), "c")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("x", in: map), "y")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("z", in: map), "z")
        // A cycle terminates (rather than looping forever) at a cycle member.
        XCTAssertTrue(["a", "b"].contains(ShareCatalogStore.resolveAlias("a", in: ["a": "b", "b": "a"])))
    }

    func testAddsVariantWordBlocksParodyUpgrade() {
        // "sword art online" must never upgrade to "sword art online abridged".
        XCTAssertTrue(ShareCatalogStore.addsVariantWord(base: "sword art online", extended: "sword art online abridged"))
        // A genuine subtitle extension is allowed ("avatar" → "avatar the last airbender").
        XCTAssertFalse(ShareCatalogStore.addsVariantWord(base: "avatar", extended: "avatar the last airbender"))
    }

    func testEpisodeHintsSkipSyntheticPlaceholders() async {
        // A show with bare-numbered early seasons stores "S1·E01" placeholder titles;
        // those must be excluded from disambiguation hints so the real later-season
        // titles are used (the Outlander bug).
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        func ep(_ path: String, _ season: Int, _ episode: Int, title: String) -> CatalogAsset {
            CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1,
                         modifiedAt: Date(), kind: .episode, library: .tv,
                         title: title, year: nil, seriesTitle: "Outlander",
                         seriesKey: ShareCatalogID.seriesKey(fromTitle: "Outlander"),
                         season: season, episode: episode)
        }
        await store.upsert([
            ep("TV/Outlander/S01/o.s01e01.mkv", 1, 1, title: "S1·E01"),
            ep("TV/Outlander/S01/o.s01e02.mkv", 1, 2, title: "S1·E02"),
            ep("TV/Outlander/S02/o.s02e01.mkv", 2, 1, title: "Through a Glass, Darkly"),
            ep("TV/Outlander/S02/o.s02e02.mkv", 2, 2, title: "Not in Scotland Anymore"),
        ], scanID: 1)
        let key = ShareCatalogID.seriesKey(fromTitle: "Outlander")
        let hints = await store.episodeTitleHints(seriesKey: key)
        XCTAssertEqual(hints.map(\.title), ["Through a Glass, Darkly", "Not in Scotland Anymore"])
        XCTAssertFalse(hints.contains { $0.title.hasPrefix("S1·E") }, "placeholders excluded")
    }

    func testSearchAlternatesExcludeShorterAbbreviations() async {
        // A cryptic filename abbreviation ("TP" under a "The Punisher" folder) must
        // NOT be offered as a search alternate — only a RICHER (more-word) filename
        // title qualifies (the Punisher bug). A generic folder with a longer filename
        // title ("Avatar" folder, "Avatar The Last Airbender" files) still yields one.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        func ep(_ path: String, series: String, key: String, _ s: Int, _ e: Int) -> CatalogAsset {
            CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1,
                         modifiedAt: Date(), kind: .episode, library: .tv,
                         title: "t", year: nil, seriesTitle: series, seriesKey: key, season: s, episode: e)
        }
        let punisher = ShareCatalogID.seriesKey(fromTitle: "The Punisher")
        let avatar = ShareCatalogID.seriesKey(fromTitle: "Avatar")
        await store.upsert([
            ep("TV/The Punisher/TP.S01E01.3AM.mkv", series: "The Punisher", key: punisher, 1, 1),
            ep("TV/Avatar (2024)/Avatar.The.Last.Airbender.2024.S01E01.mkv", series: "Avatar", key: avatar, 1, 1),
        ], scanID: 1)
        let punisherAlts = await store.seriesSearchTitleAlternates(seriesKey: punisher, storedTitle: "The Punisher")
        XCTAssertFalse(punisherAlts.contains { $0.caseInsensitiveCompare("TP") == .orderedSame }, "abbreviation excluded")
        let avatarAlts = await store.seriesSearchTitleAlternates(seriesKey: avatar, storedTitle: "Avatar")
        XCTAssertTrue(avatarAlts.contains("Avatar The Last Airbender"), "richer filename title kept")
    }
}
