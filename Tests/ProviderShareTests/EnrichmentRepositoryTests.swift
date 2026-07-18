import XCTest
import CoreModels
@testable import ProviderShare

/// Direct tests for the Batch-16 extraction out of `ShareCatalogStore`:
/// `EnrichmentRepository` — the synchronous, transaction-free external/local
/// enrichment persistence + backlog-query + legacy-migration + provider-id SQL
/// mechanics over one actor-confined `CatalogConnection`. The whole-behavior net
/// is the `ProviderShareTests` suite (the store facade forwards to this repo
/// verbatim, and `saveEnrichment`/`pendingEnrichment(forItemID:)` delegate the
/// leaf SQL); these prove the extracted mechanics in isolation under one
/// serialized connection, without a whole catalog or the store actor.
final class EnrichmentRepositoryTests: XCTestCase {
    private func openConnection() -> (CatalogConnection, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrich-repo-\(UUID().uuidString).sqlite")
        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        return (conn, url)
    }

    // MARK: - seed helpers

    private func seedMovieAsset(
        _ conn: CatalogConnection,
        relPath: String,
        firstSeen: Double = 1,
        library: String = "movies",
        explicitIDs: String? = nil
    ) {
        let ex = explicitIDs.map { "'\($0)'" } ?? "NULL"
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, year, explicit_ids_json)
            VALUES('\(relPath)', 'base', 10, 0, \(firstSeen), 1,
              'movie', '\(library)', 'Title', 'title', 2020, \(ex));
            """))
    }

    private func seedEpisodeAsset(
        _ conn: CatalogConnection,
        relPath: String,
        seriesKey: String,
        firstSeen: Double = 1,
        library: String = "tv"
    ) {
        XCTAssertTrue(conn.exec("""
            INSERT INTO assets(
              rel_path, basename, size, modified_at, first_seen_at, last_scan,
              kind, library, title, sort_title, series_title, series_key, season, episode)
            VALUES('\(relPath)', 'base', 10, 0, \(firstSeen), 1,
              'episode', '\(library)', 'Ep', 'ep', 'Show', '\(seriesKey)', 1, 1);
            """))
    }

    private func seedEnrichmentRow(
        _ conn: CatalogConnection,
        itemID: String,
        version: Int,
        usable: Bool,
        attempts: Int = 0,
        enrichedAt: Double = 0
    ) {
        let ids = usable ? "'{\"tvdb\":\"1\"}'" : "NULL"
        XCTAssertTrue(conn.exec("""
            INSERT INTO enrichment(item_id, provider_ids_json, enriched_at, enrich_version, attempts)
            VALUES('\(itemID)', \(ids), \(enrichedAt), \(version), \(attempts));
            """))
    }

    private func record(
        ids: [String: String] = [:],
        overview: String? = nil,
        genres: [String] = [],
        source: MetadataSource = .tvdb
    ) -> EnrichmentRecord {
        var r = EnrichmentRecord()
        r.providerIDs = ids
        r.overview = overview
        r.genres = genres
        for k in ids.keys { r.provenance[.providerID(k)] = MetadataAttribution(source: source) }
        if overview != nil { r.provenance[.overview] = MetadataAttribution(source: source) }
        if !genres.isEmpty { r.provenance[.genres] = MetadataAttribution(source: source) }
        return r
    }

    private func metadataValueCount(_ conn: CatalogConnection, itemID: String, source: String? = nil) -> Int {
        var v = 0
        let clause = source.map { " AND source='\($0)'" } ?? ""
        conn.query("SELECT COUNT(*) FROM metadata_values WHERE item_id='\(itemID)'\(clause);") {
            v = Int(CatalogConnection.columnDouble($0, 0))
        }
        return v
    }

    // MARK: - external write scoping

    func testWriteMetadataValuesReplaceScopedToNonLocalSources() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        let item = "f:m.mkv"

        // A pre-existing localNFO + filename candidate the local worker owns, plus a
        // stale external row an earlier pass wrote.
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','title','localNFO','\"Local\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','providerID.imdb','filename','\"tt1\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','overview','tvdb','\"stale\"');"))

        XCTAssertTrue(repo.writeMetadataValues(
            itemID: item, record: record(overview: "fresh"), refreshedAt: Date(), replaceExisting: true
        ))

        // localNFO + filename untouched; the external overview replaced not duplicated.
        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "localNFO"), 1)
        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "filename"), 1)
        var overview: String?
        conn.query("SELECT value_json FROM metadata_values WHERE item_id='\(item)' AND field='overview' AND source='tvdb';") {
            overview = CatalogConnection.columnText($0, 0)
        }
        XCTAssertEqual(overview, "\"fresh\"")
    }

    func testWriteMetadataValuesNonReplaceDoesNotClobber() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        let item = "f:m.mkv"

        XCTAssertTrue(repo.writeMetadataValues(
            itemID: item, record: record(overview: "first"), refreshedAt: Date(), replaceExisting: false
        ))
        // INSERT OR IGNORE: a second non-replace write cannot overwrite the first.
        XCTAssertTrue(repo.writeMetadataValues(
            itemID: item, record: record(overview: "second"), refreshedAt: Date(), replaceExisting: false
        ))
        var overview: String?
        conn.query("SELECT value_json FROM metadata_values WHERE item_id='\(item)' AND field='overview';") {
            overview = CatalogConnection.columnText($0, 0)
        }
        XCTAssertEqual(overview, "\"first\"")
    }

    // MARK: - enrichment state independence

    func testWriteEnrichmentStateReplaceVsCoalesceAndLocalIndependence() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        let item = "f:m.mkv"

        // Local state written first — must be preserved through every external write.
        XCTAssertTrue(repo.writeLocalEnrichmentState(itemID: item, version: 3, attempts: 1))
        XCTAssertTrue(repo.writeEnrichmentState(itemID: item, version: 10, attempts: 2, replaceExisting: true))
        XCTAssertEqual(repo.localEnrichmentState(itemID: item)?.version, 3)
        XCTAssertEqual(repo.localEnrichmentState(itemID: item)?.attempts, 1)

        var ext: (Int, Int) = (0, 0)
        conn.query("SELECT external_version, external_attempts FROM metadata_enrichment_state WHERE item_id='\(item)';") {
            ext = (Int(CatalogConnection.columnDouble($0, 0)), Int(CatalogConnection.columnDouble($0, 1)))
        }
        XCTAssertEqual(ext.0, 10)
        XCTAssertEqual(ext.1, 2)

        // Non-replace COALESCE: existing external_version kept, attempts preserved.
        XCTAssertTrue(repo.writeEnrichmentState(itemID: item, version: 99, attempts: 7, replaceExisting: false))
        conn.query("SELECT external_version, external_attempts FROM metadata_enrichment_state WHERE item_id='\(item)';") {
            ext = (Int(CatalogConnection.columnDouble($0, 0)), Int(CatalogConnection.columnDouble($0, 1)))
        }
        XCTAssertEqual(ext.0, 10, "COALESCE keeps the existing external version")
        XCTAssertEqual(ext.1, 2, "existing external attempts preserved when version present")
        // Local lane still untouched by the external writes.
        XCTAssertEqual(repo.localEnrichmentState(itemID: item)?.version, 3)
    }

    // MARK: - merge

    func testMergedUnionsProviderIDsAndPrefersNewNonEmpty() {
        let existing = record(ids: ["imdb": "tt1"], overview: "old")
        var incoming = record(ids: ["tvdb": "99"], overview: "new")
        incoming.genres = ["Drama"]
        incoming.provenance[.genres] = MetadataAttribution(source: .tvdb)

        let merged = EnrichmentRepository.merged(existing: existing, new: incoming)
        XCTAssertEqual(merged.providerIDs["imdb"], "tt1")
        XCTAssertEqual(merged.providerIDs["tvdb"], "99")
        XCTAssertEqual(merged.overview, "new")
        XCTAssertEqual(merged.genres, ["Drama"])

        // nil existing returns new verbatim.
        XCTAssertEqual(EnrichmentRepository.merged(existing: nil, new: incoming), incoming)
    }

    // MARK: - version/attempts + usable probe

    func testVersionAttemptsAndUsableProbe() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        seedEnrichmentRow(conn, itemID: "f:u.mkv", version: 14, usable: true, attempts: 0)
        seedEnrichmentRow(conn, itemID: "f:miss.mkv", version: 14, usable: false, attempts: 2)

        XCTAssertEqual(repo.enrichmentVersionAndAttempts(itemID: "f:miss.mkv")?.version, 14)
        XCTAssertEqual(repo.enrichmentVersionAndAttempts(itemID: "f:miss.mkv")?.attempts, 2)
        XCTAssertNil(repo.enrichmentVersionAndAttempts(itemID: "f:absent.mkv"))

        XCTAssertTrue(repo.hasUsableEnrichment(itemID: "f:u.mkv", version: 14))
        XCTAssertFalse(repo.hasUsableEnrichment(itemID: "f:u.mkv", version: 99), "wrong version is not usable")
        XCTAssertFalse(repo.hasUsableEnrichment(itemID: "f:miss.mkv", version: 14), "an unusable miss row is not usable")
    }

    // MARK: - pending backlog

    func testPendingEnrichmentBacklogRetryCapAndLimit() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)

        // Never-enriched movie (pending), usable movie (not pending), capped miss
        // (>= maxAttempts, not pending), retryable miss (< cap, pending).
        seedMovieAsset(conn, relPath: "new.mkv", firstSeen: 1)
        seedMovieAsset(conn, relPath: "done.mkv", firstSeen: 2)
        seedEnrichmentRow(conn, itemID: "f:done.mkv", version: 14, usable: true)
        seedMovieAsset(conn, relPath: "capped.mkv", firstSeen: 3)
        seedEnrichmentRow(conn, itemID: "f:capped.mkv", version: 14, usable: false, attempts: 3)
        seedMovieAsset(conn, relPath: "retry.mkv", firstSeen: 4)
        seedEnrichmentRow(conn, itemID: "f:retry.mkv", version: 14, usable: false, attempts: 1)
        // A pending series.
        seedEpisodeAsset(conn, relPath: "Show/s01e01.mkv", seriesKey: "show", firstSeen: 5)

        let pending = repo.pendingEnrichment(version: 14, limit: 10)
        let ids = pending.map(\.itemID)
        XCTAssertTrue(ids.contains("f:new.mkv"))
        XCTAssertTrue(ids.contains("f:retry.mkv"))
        XCTAssertTrue(ids.contains("series:show"))
        XCTAssertFalse(ids.contains("f:done.mkv"))
        XCTAssertFalse(ids.contains("f:capped.mkv"))

        // Movies ordered by first_seen before series; limit bounds the slice.
        XCTAssertEqual(repo.pendingEnrichment(version: 14, limit: 1).map(\.itemID), ["f:new.mkv"])
        XCTAssertTrue(repo.pendingEnrichment(version: 14, limit: 0).isEmpty)

        // Count matches the eligible set (2 movies + 1 series).
        XCTAssertEqual(repo.pendingEnrichmentCount(version: 14), 3)
    }

    // MARK: - orphan cleanup

    func testDeleteOrphanMetadataRemovesRowsWithNoLiveAsset() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)

        seedMovieAsset(conn, relPath: "live.mkv")
        seedEpisodeAsset(conn, relPath: "Show/s01e01.mkv", seriesKey: "liveshow")
        // Live + orphan enrichment / values / state rows.
        seedEnrichmentRow(conn, itemID: "f:live.mkv", version: 14, usable: true)
        seedEnrichmentRow(conn, itemID: "f:gone.mkv", version: 14, usable: true)
        seedEnrichmentRow(conn, itemID: "series:liveshow", version: 14, usable: true)
        seedEnrichmentRow(conn, itemID: "series:goneshow", version: 14, usable: true)
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('f:gone.mkv','title','tvdb','\"x\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_enrichment_state(item_id, external_version) VALUES('f:gone.mkv', 14);"))

        XCTAssertTrue(repo.deleteOrphanMetadataInTransaction())

        func exists(_ table: String, _ id: String) -> Bool {
            var n = 0
            conn.query("SELECT COUNT(*) FROM \(table) WHERE item_id='\(id)';") { n = Int(CatalogConnection.columnDouble($0, 0)) }
            return n > 0
        }
        XCTAssertTrue(exists("enrichment", "f:live.mkv"))
        XCTAssertTrue(exists("enrichment", "series:liveshow"))
        XCTAssertFalse(exists("enrichment", "f:gone.mkv"))
        XCTAssertFalse(exists("enrichment", "series:goneshow"))
        XCTAssertFalse(exists("metadata_values", "f:gone.mkv"))
        XCTAssertFalse(exists("metadata_enrichment_state", "f:gone.mkv"))
    }

    // MARK: - legacy migration

    func testMigrateLegacyEnrichmentMetadataBackfillsAndIsIdempotent() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        XCTAssertTrue(conn.exec("""
            INSERT INTO enrichment(item_id, provider_ids_json, overview, enriched_at, enrich_version, attempts, title)
            VALUES('f:legacy.mkv', '{"tvdb":"7"}', 'Legacy overview', 0, 14, 0, 'Legacy Title');
            """))

        XCTAssertTrue(repo.migrateLegacyEnrichmentMetadata())
        XCTAssertGreaterThan(metadataValueCount(conn, itemID: "f:legacy.mkv"), 0)
        var stateVersion: Int?
        conn.query("SELECT external_version FROM metadata_enrichment_state WHERE item_id='f:legacy.mkv';") {
            stateVersion = Int(CatalogConnection.columnDouble($0, 0))
        }
        XCTAssertEqual(stateVersion, 14)

        // Idempotent: a second migration writes nothing new (INSERT OR IGNORE / COALESCE).
        let before = metadataValueCount(conn, itemID: "f:legacy.mkv")
        XCTAssertTrue(repo.migrateLegacyEnrichmentMetadata())
        XCTAssertEqual(metadataValueCount(conn, itemID: "f:legacy.mkv"), before)
    }

    // MARK: - local NFO projection write

    func testReplaceLocalNFOMetadataValuesDeleteThenInsertScopedToLocalNFO() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        let item = "f:m.mkv"
        // A pre-existing external row must survive a localNFO replace.
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','overview','tvdb','\"ext\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','title','localNFO','\"Old\"');"))

        let candidates = [
            ShareLocalMetadataFieldCandidate(field: .title, valueJSON: "\"New\"", source: .localNFO, sourceRevision: "rev1"),
            ShareLocalMetadataFieldCandidate(field: .genres, valueJSON: "[\"Sci-Fi\"]", source: .localNFO, sourceRevision: "rev1")
        ]
        XCTAssertTrue(repo.replaceLocalNFOMetadataValues(itemID: item, candidates: candidates))

        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "localNFO"), 2)
        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "tvdb"), 1, "external row untouched")
        var title: String?
        conn.query("SELECT value_json FROM metadata_values WHERE item_id='\(item)' AND field='title' AND source='localNFO';") {
            title = CatalogConnection.columnText($0, 0)
        }
        XCTAssertEqual(title, "\"New\"")

        // Empty candidates deletes the localNFO lane without touching external.
        XCTAssertTrue(repo.replaceLocalNFOMetadataValues(itemID: item, candidates: []))
        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "localNFO"), 0)
        XCTAssertEqual(metadataValueCount(conn, itemID: item, source: "tvdb"), 1)
    }

    // MARK: - provider ids

    func testExplicitAndLocalProviderIDs() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = EnrichmentRepository(connection: conn)
        seedMovieAsset(conn, relPath: "m.mkv", explicitIDs: "{\"imdb\":\"tt42\"}")
        XCTAssertEqual(repo.explicitProviderIDs(relPath: "m.mkv"), ["imdb": "tt42"])
        XCTAssertTrue(repo.explicitProviderIDs(relPath: "absent.mkv").isEmpty)

        // localNFO wins over filename for the same namespace.
        let item = "f:m.mkv"
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','providerID.tvdb','filename','\"111\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','providerID.tvdb','localNFO','\"222\"');"))
        XCTAssertTrue(conn.exec("INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','providerID.imdb','filename','\"tt5\"');"))
        let ids = repo.localProviderIDs(forItemID: item)
        XCTAssertEqual(ids["tvdb"], "222")
        XCTAssertEqual(ids["imdb"], "tt5")
    }
}
