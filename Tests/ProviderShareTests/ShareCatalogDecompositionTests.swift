import XCTest
import CoreModels
@testable import ProviderShare

/// Direct tests for the Batch-4 extractions out of `ShareCatalogStore`:
/// `CatalogConnection` (actor-confined SQLite mechanics) and
/// `ShareCatalogReadProjection` (pure row/candidate → `MediaItem` mapping). The
/// full behavior-preservation net is the 305-test `ProviderShareTests` suite;
/// these add focused, fixture-light coverage of the extracted seams themselves so
/// the mapper/reconciler policy is testable without a whole catalog.
final class ShareCatalogDecompositionTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-conn-\(UUID().uuidString).sqlite")
    }

    // MARK: - CatalogConnection

    func testConnectionCommitPersistsAcrossReopen() {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        // Schema is committed and open (not mid-transaction), so this auto-commits.
        XCTAssertTrue(conn.runUpdate("INSERT INTO meta(key, value) VALUES (?, ?);") {
            CatalogConnection.bindText($0, 1, "probe")
            CatalogConnection.bindText($0, 2, "kept")
        })
        var version = -1
        conn.query("PRAGMA user_version;") { version = Int(CatalogConnection.columnDouble($0, 0)) }
        XCTAssertEqual(version, 3, "Step 4 local-artwork migration must reach schema version 3")

        // A brand-new connection over the same file sees the committed row.
        let reopened = CatalogConnection(url: url)
        XCTAssertTrue(reopened.ensureOpen(legacyMetadataMigration: { _ in true }))
        var value: String?
        reopened.query("SELECT value FROM meta WHERE key='probe';") { value = CatalogConnection.columnText($0, 0) }
        XCTAssertEqual(value, "kept")
    }

    func testConnectionRollbackDiscardsUncommittedWrites() {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        XCTAssertTrue(conn.exec("BEGIN IMMEDIATE;"))
        XCTAssertTrue(conn.runUpdate("INSERT INTO meta(key, value) VALUES (?, ?);") {
            CatalogConnection.bindText($0, 1, "temp")
            CatalogConnection.bindText($0, 2, "gone")
        })
        XCTAssertTrue(conn.exec("ROLLBACK;"))

        var found = false
        conn.query("SELECT 1 FROM meta WHERE key='temp';") { _ in found = true }
        XCTAssertFalse(found, "A rolled-back write must leave no row through the connection seam")
    }

    // MARK: - ShareCatalogReadProjection.applyEnrichment

    func testApplyEnrichmentFillsMissingWithoutClobbering() {
        var item = MediaItem(id: "f:m.mkv", title: "My Movie", kind: .movie)
        item.overview = "Existing overview"
        item.providerIDs = ["Imdb": "tt1"]

        var rec = EnrichmentRecord()
        rec.providerIDs = ["Imdb": "tt-WRONG", "Tmdb": "27205"] // must not clobber Imdb
        rec.overview = "External overview"                       // must not clobber existing
        rec.genres = ["Sci-Fi"]                                  // fills empty
        rec.runtime = 7200                                       // fills empty (movie)
        rec.posterURL = URL(string: "https://img/p.jpg")

        let out = ShareCatalogReadProjection.applyEnrichment(item, rec)
        XCTAssertEqual(out.providerIDs["Imdb"], "tt1")           // kept
        XCTAssertEqual(out.providerIDs["Tmdb"], "27205")         // merged in
        XCTAssertEqual(out.overview, "Existing overview")        // not clobbered
        XCTAssertEqual(out.genres, ["Sci-Fi"])                   // filled
        XCTAssertEqual(out.runtime, 7200)                        // filled
        XCTAssertEqual(out.posterURL, URL(string: "https://img/p.jpg"))
    }

    func testApplyEnrichmentUpgradesNearIdenticalSeriesTitleButNotDown() {
        var typo = MediaItem(id: "series:pb", title: "Peaky Blinder", kind: .series)
        typo.seriesID = "series:pb"
        var rec = EnrichmentRecord()
        rec.title = "Peaky Blinders"
        XCTAssertEqual(ShareCatalogReadProjection.applyEnrichment(typo, rec).title, "Peaky Blinders")

        // A wholly different resolved title (a spin-off that mismatched its parent)
        // must never rename the show down.
        var spinoff = MediaItem(id: "series:x", title: "Better Call Saul", kind: .series)
        spinoff.seriesID = "series:x"
        var recBad = EnrichmentRecord()
        recBad.title = "Breaking Bad"
        XCTAssertEqual(ShareCatalogReadProjection.applyEnrichment(spinoff, recBad).title, "Better Call Saul")
    }

    func testApplyEnrichmentEpisodeUsesSeriesArtAndSkipsOverview() {
        var episode = MediaItem(id: "f:s01e01.mkv", title: "Pilot", kind: .episode)
        episode.seriesID = "series:x"
        var rec = EnrichmentRecord()
        rec.overview = "Series synopsis"
        rec.posterURL = URL(string: "https://img/show.jpg")

        let out = ShareCatalogReadProjection.applyEnrichment(episode, rec)
        XCTAssertNil(out.overview, "Episode must not inherit the series overview")
        XCTAssertEqual(out.seriesPosterURL, URL(string: "https://img/show.jpg"))
        XCTAssertNil(out.posterURL, "Series art is a fallback field, not the episode's own poster")
    }

    // MARK: - ShareCatalogReadProjection.applyLocalMetadata

    private func localRow(_ source: MetadataSource, _ json: String) -> ShareCatalogReadProjection.LocalFieldRow {
        ShareCatalogReadProjection.LocalFieldRow(source: source, valueJSON: json)
    }

    func testApplyLocalMetadataOverridesWithProvenance() {
        var item = MediaItem(id: "f:m.mkv", title: "External Title", kind: .movie)
        item.genres = ["External"]
        item.providerIDs = ["Tmdb": "999"]

        let fields: [MetadataField: ShareCatalogReadProjection.LocalFieldRow] = [
            .title: localRow(.localNFO, CatalogJSON.encode("NFO Title")!),
            .genres: localRow(.localNFO, CatalogJSON.encode(["Drama", "Crime"])!),
            .runtime: localRow(.localNFO, CatalogJSON.encode(TimeInterval(5400))!),
            MetadataField(rawValue: "providerID.tmdb"): localRow(.localNFO, CatalogJSON.encode("27205")!),
        ]

        let out = ShareCatalogReadProjection.applyLocalMetadata(item, fields)
        XCTAssertEqual(out.title, "NFO Title")
        XCTAssertEqual(out.genres, ["Drama", "Crime"])
        XCTAssertEqual(out.runtime, 5400)
        XCTAssertTrue(out.providerIDs.values.contains("27205"))
        XCTAssertFalse(out.providerIDs.values.contains("999"), "Local id replaces the same namespace")
        XCTAssertEqual(out.metadataProvenance[.title]?.source, .localNFO)
        XCTAssertNil(out.metadataProvenance[.title]?.sourceURL, "Local provenance is always path-free")
    }

    func testApplyLocalMetadataProjectsRecognizedRatingsOnly() {
        let ratings = [
            ParsedNFORating(source: "imdb", value: 8.6, max: 10, votes: 1000, isDefault: true),
            ParsedNFORating(source: "rottentomatoes", value: 92, max: 100, votes: nil, isDefault: false),
        ]
        let fields: [MetadataField: ShareCatalogReadProjection.LocalFieldRow] = [
            .ratings: localRow(.localNFO, CatalogJSON.encode(ratings)!)
        ]
        let out = ShareCatalogReadProjection.applyLocalMetadata(
            MediaItem(id: "f:m.mkv", title: "M", kind: .movie), fields
        )
        XCTAssertTrue(out.ratings.contains { $0.source == .imdb && abs($0.value - 8.6) < 0.001 })
        XCTAssertFalse(out.ratings.contains { $0.source == .tmdb },
                       "An unrecognized rating source must not project")
    }

    // MARK: - Pure item builders

    func testSeriesItemProjection() {
        let item = ShareCatalogReadProjection.seriesItem(
            key: "peaky-blinders", title: "Peaky Blinders", library: .tv, year: 2013
        )
        XCTAssertEqual(item.kind, .series)
        XCTAssertEqual(item.title, "Peaky Blinders")
        XCTAssertEqual(item.productionYear, 2013)
        XCTAssertEqual(item.id, ShareCatalogID.series("peaky-blinders"))
        XCTAssertEqual(item.seriesID, ShareCatalogID.series("peaky-blinders"))
    }
}
