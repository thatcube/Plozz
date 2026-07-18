import XCTest
@testable import ProviderShare
import CoreModels
import SQLite3

/// Batch 5 (findings B1/B2/B3): the atomic clean-scan finalization.
///
/// Before Batch 5 a clean scan deleted vanished `assets` but left their
/// `enrichment`/`metadata_values`/`metadata_enrichment_state` rows behind, so a
/// later reuse of the same `rel_path` or `series_key` resurrected the deleted
/// item's ids/artwork/overview/completed state. Sidecar value-cache cleanup also
/// built a `rel_path IN (?, ?, …)` list that broke past the SQLite variable
/// limit. `finalizeCleanScan` replaces the whole multi-pass flow with one atomic
/// transaction: prune assets, delete every orphan row via `NOT EXISTS`, regroup,
/// recompute associations, and rematerialize local + filename projections — all
/// or nothing. These tests drive the real SQLite store and inspect the on-disk
/// catalog directly.
final class ShareCleanScanFinalizationTests: XCTestCase {

    // MARK: - Fixtures / helpers

    private func movieAsset(
        _ path: String,
        title: String,
        year: Int?,
        movieKey: String? = nil,
        movieTitleKey: String? = nil,
        explicitIDs: [String: String] = [:]
    ) -> CatalogAsset {
        CatalogAsset(
            relPath: path,
            basename: (path as NSString).lastPathComponent,
            size: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 100),
            kind: .movie,
            library: .movies,
            title: title,
            year: year,
            seriesTitle: nil,
            seriesKey: nil,
            season: nil,
            episode: nil,
            movieKey: movieKey,
            movieTitleKey: movieTitleKey,
            explicitProviderIDs: explicitIDs
        )
    }

    private func episodeAsset(
        _ path: String,
        series: String,
        key: String,
        season: Int,
        episode: Int,
        explicitIDs: [String: String] = [:],
        metadataRoot: String? = nil
    ) -> CatalogAsset {
        CatalogAsset(
            relPath: path,
            basename: (path as NSString).lastPathComponent,
            size: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 100),
            kind: .episode,
            library: .tv,
            title: "Episode \(episode)",
            year: nil,
            seriesTitle: series,
            seriesKey: key,
            season: season,
            episode: episode,
            explicitProviderIDs: explicitIDs,
            metadataRoot: metadataRoot
        )
    }

    /// Persist a real, parsed, associated local-NFO lane for `itemID` so orphan
    /// cleanup has genuine `local_metadata_files` + `local_metadata_file_values` +
    /// `metadata_values(localNFO)` + `metadata_enrichment_state(local_version)`
    /// rows to remove.
    private func seedLocalNFO(
        _ store: ShareCatalogStore,
        video: String,
        nfo: String,
        parentDir: String,
        itemID: String,
        kind: LocalSidecarKind = .movieStem,
        scanID: Int64
    ) async {
        await store.upsertSidecars(
            [
                LocalSidecarCandidate(
                    relPath: nfo,
                    parentDir: parentDir,
                    basename: (nfo as NSString).lastPathComponent,
                    kind: kind,
                    size: 100,
                    modifiedAt: Date(timeIntervalSince1970: 100),
                    stableFileID: nil,
                    strongETag: "\"fp-\(nfo)\"",
                    changeToken: nil,
                    associatedVideoRelPath: video
                )
            ],
            scanID: scanID
        )
        await store.reconcileSidecarAssociations()
        _ = await store.writeSidecarValueCache(relPath: nfo, fields: [.overview: "\"Local overview\""])
        _ = await store.markSidecarProcessed(
            relPath: nfo,
            status: "parsed",
            fingerprint: "fp-\(nfo)",
            associatedItemID: itemID
        )
        _ = await store.materializeCachedLocalMetadata(itemID: itemID)
        _ = await store.writeLocalEnrichmentState(
            itemID: itemID,
            version: ShareLocalMetadataEnricher.version,
            attempts: 0
        )
    }

    private func seedExternal(
        _ store: ShareCatalogStore,
        itemID: String,
        providerIDs: [String: String] = ["tmdb": "123"],
        overview: String = "External overview"
    ) async {
        _ = await store.saveEnrichment(
            itemID: itemID,
            .init(providerIDs: providerIDs, overview: overview,
                  posterURL: URL(string: "https://example.com/p.jpg")),
            version: ShareEnricher.version
        )
    }

    private func count(_ fixture: ShareCatalogSQLiteFixture, _ table: String, itemID: String) throws -> Int {
        try fixture.integer("SELECT COUNT(*) FROM \(table) WHERE item_id='\(itemID)';")
    }

    private func metadataRowCount(_ fixture: ShareCatalogSQLiteFixture, itemID: String) throws -> Int {
        try count(fixture, "enrichment", itemID: itemID)
            + count(fixture, "metadata_values", itemID: itemID)
            + count(fixture, "metadata_enrichment_state", itemID: itemID)
    }

    // MARK: - B1: orphan metadata cleanup on deletion / reuse

    func testCleanScanRemovesOrphanMetadataWhenAssetDeleted() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let gonePath = "Movies/Gone (2001)/Gone (2001).mkv"
        let goneNFO = "Movies/Gone (2001)/Gone (2001).nfo"
        let goneID = ShareCatalogID.file(gonePath)
        let keepPath = "Movies/Keep (2000)/Keep (2000).mkv"
        let keepID = ShareCatalogID.file(keepPath)

        await store.upsert([
            movieAsset(gonePath, title: "Gone", year: 2001),
            movieAsset(keepPath, title: "Keep", year: 2000),
        ], scanID: 1)
        await seedExternal(store, itemID: goneID)
        await seedExternal(store, itemID: keepID)
        await seedLocalNFO(store, video: gonePath, nfo: goneNFO,
                           parentDir: "Movies/Gone (2001)", itemID: goneID, scanID: 1)

        // Sanity: both items have metadata before the delete.
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: goneID), 0)
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: keepID), 0)

        // Scan 2 re-sees only "Keep".
        await store.upsert([movieAsset(keepPath, title: "Keep", year: 2000)], scanID: 2)
        let ok = await store.finalizeCleanScan(inScan: 2)
        XCTAssertTrue(ok)

        // Every orphan row for the deleted item is gone across all three tables.
        XCTAssertEqual(try metadataRowCount(fixture, itemID: goneID), 0,
                       "deleted asset must leave no enrichment/metadata_values/state rows")
        XCTAssertEqual(try fixture.integer(
            "SELECT COUNT(*) FROM local_metadata_files WHERE rel_path='\(goneNFO)';"), 0)
        XCTAssertEqual(try fixture.integer(
            "SELECT COUNT(*) FROM local_metadata_file_values WHERE rel_path='\(goneNFO)';"), 0)
        // The surviving item keeps all of its metadata.
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: keepID), 0)
    }

    func testPathReuseDoesNotResurrectDeletedMetadata() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let path = "Movies/Reused/Reused.mkv"
        let id = ShareCatalogID.file(path)

        await store.upsert([movieAsset(path, title: "First Film", year: 1999)], scanID: 1)
        await seedExternal(store, itemID: id, providerIDs: ["tmdb": "111"], overview: "OLD overview")
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: id), 0)

        // Scan 2: the file at that path is gone entirely.
        await store.upsert([movieAsset("Movies/Other/Other.mkv", title: "Other", year: 2005)], scanID: 2)
        await finalizeExpectingSuccess(store, inScan: 2)
        XCTAssertEqual(try metadataRowCount(fixture, itemID: id), 0)

        // Scan 3: a DIFFERENT movie reuses the exact same path.
        await store.upsert([movieAsset(path, title: "Second Film", year: 2020)], scanID: 3)
        await finalizeExpectingSuccess(store, inScan: 3)

        let item = await store.item(id: id)
        XCTAssertEqual(item?.productionYear, 2020, "path now resolves to the NEW film")
        XCTAssertNil(item?.overview, "the deleted film's overview must not resurrect")
        XCTAssertEqual(try count(fixture, "enrichment", itemID: id), 0,
                       "reused path starts with no external enrichment (pending)")
    }

    func testGroupedMovieRepresentativeDeletionKeepsLiveVersion() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        // Two versions of one film share a movie group. Representative = MIN rel_path.
        let hd = "Movies/Film (2010)/Film (2010) - 1080p.mkv"
        let uhd = "Movies/Film (2010)/Film (2010) - 2160p.mkv"
        let hdID = ShareCatalogID.file(hd)
        let key = "film-2010"
        await store.upsert([
            movieAsset(hd, title: "Film", year: 2010, movieKey: key, movieTitleKey: "film"),
            movieAsset(uhd, title: "Film", year: 2010, movieKey: key, movieTitleKey: "film"),
        ], scanID: 1)
        await store.rebuildMovieGroups()
        // External enrichment is keyed to the group representative (the HD file).
        await seedExternal(store, itemID: hdID)
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: hdID), 0)

        // Scan 2 loses the HD representative; the UHD version survives.
        await store.upsert([
            movieAsset(uhd, title: "Film", year: 2010, movieKey: key, movieTitleKey: "film"),
        ], scanID: 2)
        await finalizeExpectingSuccess(store, inScan: 2)

        // The old representative's rows are orphaned and removed.
        XCTAssertEqual(try metadataRowCount(fixture, itemID: hdID), 0)
        // The film still resolves via the surviving version.
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(movies.first?.title, "Film")
    }

    func testEpisodeDeletionRemovesEpisodeRowsButKeepsSeries() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let key = ShareCatalogID.seriesKey(fromTitle: "The Show")
        let ep1 = "TV/The Show/S01/E01.mkv"
        let ep2 = "TV/The Show/S01/E02.mkv"
        let ep1ID = ShareCatalogID.file(ep1)
        let seriesID = ShareCatalogID.series(key)

        await store.upsert([
            episodeAsset(ep1, series: "The Show", key: key, season: 1, episode: 1),
            episodeAsset(ep2, series: "The Show", key: key, season: 1, episode: 2),
        ], scanID: 1)
        await seedExternal(store, itemID: seriesID, providerIDs: ["tvdb": "999"])
        await seedLocalNFO(store, video: ep1, nfo: "TV/The Show/S01/E01.nfo",
                           parentDir: "TV/The Show/S01", itemID: ep1ID,
                           kind: .episodeStem, scanID: 1)
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: ep1ID), 0)
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: seriesID), 0)

        // Scan 2 loses episode 1; episode 2 keeps the series alive.
        await store.upsert([
            episodeAsset(ep2, series: "The Show", key: key, season: 1, episode: 2),
        ], scanID: 2)
        await finalizeExpectingSuccess(store, inScan: 2)

        XCTAssertEqual(try metadataRowCount(fixture, itemID: ep1ID), 0,
                       "episode-local rows removed with the episode asset")
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: seriesID), 0,
                             "series rows survive while any episode remains")
    }

    func testSeriesKeyReuseAfterReopenDoesNotResurrect() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let key = ShareCatalogID.seriesKey(fromTitle: "Reboot")
        let seriesID = ShareCatalogID.series(key)
        let ep = "TV/Reboot/S01/E01.mkv"

        do {
            let store = fixture.makeStore()
            await store.upsert([episodeAsset(ep, series: "Reboot", key: key, season: 1, episode: 1)], scanID: 1)
            await seedExternal(store, itemID: seriesID, providerIDs: ["tvdb": "555"], overview: "OLD show")
            XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: seriesID), 0)
            // The whole series disappears.
            await store.upsert([episodeAsset("TV/Other/S01/E01.mkv", series: "Other",
                                             key: ShareCatalogID.seriesKey(fromTitle: "Other"),
                                             season: 1, episode: 1)], scanID: 2)
            await finalizeExpectingSuccess(store, inScan: 2)
            XCTAssertEqual(try metadataRowCount(fixture, itemID: seriesID), 0)
        }

        // Relaunch (fresh store on the same DB) and reuse the same series key.
        let reopened = fixture.makeStore()
        await reopened.upsert([episodeAsset(ep, series: "Reboot", key: key, season: 1, episode: 1)], scanID: 3)
        await finalizeExpectingSuccess(reopened, inScan: 3)
        let series = await reopened.item(id: seriesID)
        XCTAssertNil(series?.overview, "reused series key must not resurrect the old show overview")
        XCTAssertEqual(try count(fixture, "enrichment", itemID: seriesID), 0)
    }

    // MARK: - B2: relational cleanup above the SQLite variable limit

    func testSidecarValueCleanupExceedsSQLiteVariableLimit() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        // Far above SQLite's default 999-variable bind limit — the old
        // `rel_path IN (?, ?, …)` deletion would have failed to prepare; the new
        // `NOT EXISTS` cleanup carries no bound list at all.
        let total = 3_000
        var sidecars: [LocalSidecarCandidate] = []
        sidecars.reserveCapacity(total)
        for i in 0..<total {
            let nfo = "Movies/Bulk/movie\(i).nfo"
            sidecars.append(LocalSidecarCandidate(
                relPath: nfo, parentDir: "Movies/Bulk", basename: "movie\(i).nfo",
                kind: .movieStem, size: 10, modifiedAt: Date(timeIntervalSince1970: 100),
                stableFileID: nil, strongETag: "\"e\(i)\"", changeToken: nil,
                associatedVideoRelPath: "Movies/Bulk/movie\(i).mkv"
            ))
        }
        await store.upsert([movieAsset("Movies/Bulk/movie0.mkv", title: "Bulk", year: 2000)], scanID: 1)
        await store.upsertSidecars(sidecars, scanID: 1)
        for i in 0..<total {
            _ = await store.writeSidecarValueCache(
                relPath: "Movies/Bulk/movie\(i).nfo", fields: [.overview: "\"v\(i)\""])
        }
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_metadata_files;"), total)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_metadata_file_values;"), total)

        // Scan 2 re-sees none of them.
        await store.upsert([movieAsset("Movies/Bulk/movie0.mkv", title: "Bulk", year: 2000)], scanID: 2)
        await finalizeExpectingSuccess(store, inScan: 2)

        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_metadata_files;"), 0,
                       "all sidecar inventory removed, no silent skip")
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_metadata_file_values;"), 0,
                       "all value-cache rows removed with no bound IN list")
    }

    // MARK: - Partial scan never prunes

    func testFinalizeIsTheOnlyDeletionPath() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let goneID = ShareCatalogID.file("Movies/Gone/Gone.mkv")
        await store.upsert([movieAsset("Movies/Gone/Gone.mkv", title: "Gone", year: 2001)], scanID: 1)
        await seedExternal(store, itemID: goneID)

        // Scan 2 re-sees only a different asset, but a PARTIAL pass never calls
        // finalizeCleanScan — nothing is pruned.
        await store.upsert([movieAsset("Movies/Keep/Keep.mkv", title: "Keep", year: 2000)], scanID: 2)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM assets;"), 2,
                       "no prune without finalizeCleanScan")
        XCTAssertGreaterThan(try metadataRowCount(fixture, itemID: goneID), 0,
                             "metadata retained on a partial (non-finalized) scan")
    }

    // MARK: - Atomicity: per-phase failure rolls the whole transaction back

    func testPerPhaseFailureRollsBackEntireTransaction() async throws {
        let allPoints: [CleanScanFailurePoint] = [
            .afterAssetDelete, .afterMovieRegroup, .afterOrphanMetadataCleanup,
            .afterSidecarCleanup, .afterAliasCleanup, .afterAssociationRecompute,
            .afterWinnerRematerialize, .afterFilenameProjection,
        ]
        for point in allPoints {
            let fixture = ShareCatalogSQLiteFixture()
            defer { fixture.cleanup() }
            let store = fixture.makeStore()
            let gonePath = "Movies/Gone/Gone.mkv"
            let goneNFO = "Movies/Gone/Gone.nfo"
            let goneID = ShareCatalogID.file(gonePath)
            await store.upsert([
                movieAsset(gonePath, title: "Gone", year: 2001, movieKey: "gone", movieTitleKey: "gone"),
                movieAsset("Movies/Keep/Keep.mkv", title: "Keep", year: 2000,
                           movieKey: "keep", movieTitleKey: "keep"),
            ], scanID: 1)
            await store.rebuildMovieGroups()
            await seedExternal(store, itemID: goneID)
            await seedLocalNFO(store, video: gonePath, nfo: goneNFO,
                               parentDir: "Movies/Gone", itemID: goneID, scanID: 1)

            let before = try snapshot(fixture)
            let goneMetaBefore = try metadataRowCount(fixture, itemID: goneID)
            XCTAssertGreaterThan(goneMetaBefore, 0)

            // Scan 2 loses "Gone", but we inject a failure at `point`.
            await store.upsert([
                movieAsset("Movies/Keep/Keep.mkv", title: "Keep", year: 2000,
                           movieKey: "keep", movieTitleKey: "keep"),
            ], scanID: 2)
            let ok = await store.finalizeCleanScan(inScan: 2, failurePoint: point)
            XCTAssertFalse(ok, "injected failure at \(point) must fail the finalize")

            let after = try snapshot(fixture)
            XCTAssertEqual(before, after, "rollback at \(point) must restore the complete pre-finalize state")
            XCTAssertEqual(try metadataRowCount(fixture, itemID: goneID), goneMetaBefore,
                           "the deleted item's metadata is intact after rollback at \(point)")
            XCTAssertEqual(try fixture.integer("SELECT user_version FROM pragma_user_version;"), 2)
            XCTAssertEqual(try fixture.text("PRAGMA integrity_check;"), "ok")
        }
    }

    private struct CatalogSnapshot: Equatable {
        var assets: Int
        var enrichment: Int
        var metadataValues: Int
        var enrichmentState: Int
        var localFiles: Int
        var localValues: Int
        var movieAlias: Int
        var seriesMerge: Int
    }

    private func finalizeExpectingSuccess(_ store: ShareCatalogStore, inScan: Int64,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await store.finalizeCleanScan(inScan: inScan)
        XCTAssertTrue(ok, "clean-scan finalization should succeed", file: file, line: line)
    }

    private func snapshot(_ fixture: ShareCatalogSQLiteFixture) throws -> CatalogSnapshot {
        CatalogSnapshot(
            assets: try fixture.integer("SELECT COUNT(*) FROM assets;"),
            enrichment: try fixture.integer("SELECT COUNT(*) FROM enrichment;"),
            metadataValues: try fixture.integer("SELECT COUNT(*) FROM metadata_values;"),
            enrichmentState: try fixture.integer("SELECT COUNT(*) FROM metadata_enrichment_state;"),
            localFiles: try fixture.integer("SELECT COUNT(*) FROM local_metadata_files;"),
            localValues: try fixture.integer("SELECT COUNT(*) FROM local_metadata_file_values;"),
            movieAlias: try fixture.integer("SELECT COUNT(*) FROM movie_alias;"),
            seriesMerge: try fixture.integer("SELECT COUNT(*) FROM series_merge;")
        )
    }

    // MARK: - Post-commit integrity / schema stability

    func testFinalizePreservesSchemaVersionAndIntegrity() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.upsert([
            movieAsset("Movies/A/A.mkv", title: "A", year: 2000),
            movieAsset("Movies/B/B.mkv", title: "B", year: 2001),
        ], scanID: 1)
        await seedExternal(store, itemID: ShareCatalogID.file("Movies/A/A.mkv"))
        await store.upsert([movieAsset("Movies/B/B.mkv", title: "B", year: 2001)], scanID: 2)
        await finalizeExpectingSuccess(store, inScan: 2)

        XCTAssertEqual(try fixture.integer("SELECT user_version FROM pragma_user_version;"), 2)
        XCTAssertEqual(try fixture.text("PRAGMA integrity_check;"), "ok")
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM pragma_foreign_key_check;"), 0)
    }

    func testCommitExposesCorrectedProjectionOnReopen() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let gonePath = "Movies/Gone/Gone.mkv"
        let goneID = ShareCatalogID.file(gonePath)
        do {
            let store = fixture.makeStore()
            await store.upsert([
                movieAsset(gonePath, title: "Gone", year: 2001),
                movieAsset("Movies/Keep/Keep.mkv", title: "Keep", year: 2000),
            ], scanID: 1)
            await seedExternal(store, itemID: goneID)
            await store.upsert([movieAsset("Movies/Keep/Keep.mkv", title: "Keep", year: 2000)], scanID: 2)
            await finalizeExpectingSuccess(store, inScan: 2)
        }
        // A relaunch reads the corrected projection with no further scan/enrichment.
        let reopened = fixture.makeStore()
        let movies = await reopened.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Keep"])
        let goneItem = await reopened.item(id: goneID)
        XCTAssertNil(goneItem)
        XCTAssertEqual(try metadataRowCount(fixture, itemID: goneID), 0)
    }
}
