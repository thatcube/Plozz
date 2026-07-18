import XCTest
import CoreModels
@testable import ProviderShare

/// Direct tests for the Batch-15 extraction out of `ShareCatalogStore`:
/// `LocalMetadataRepository` — the synchronous, transaction-free sidecar
/// inventory / value-cache / processing-state SQL mechanics over one
/// actor-confined `CatalogConnection`. The whole-behavior net is the
/// `ProviderShareTests` suite (the store facade forwards to this repo verbatim);
/// these prove the extracted leaf mechanics in isolation under one serialized
/// connection, without a whole catalog or the store actor.
final class LocalMetadataRepositoryTests: XCTestCase {
    private func openConnection() -> (CatalogConnection, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-repo-\(UUID().uuidString).sqlite")
        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        return (conn, url)
    }

    /// Seed one `local_metadata_files` row. Only the columns the repo reads/writes
    /// matter; the rest get benign defaults.
    private func seedSidecar(
        _ conn: CatalogConnection,
        relPath: String,
        parentDir: String = "dir",
        kind: LocalSidecarKind = .movieStem,
        lastScan: Int64 = 1,
        status: String = "pending",
        attempts: Int = 0,
        parserVersion: Int? = nil,
        associatedVideo: String? = nil
    ) {
        let pv = parserVersion.map(String.init) ?? "NULL"
        let av = associatedVideo.map { "'\($0)'" } ?? "NULL"
        XCTAssertTrue(conn.exec("""
            INSERT INTO local_metadata_files(
              rel_path, parent_dir, basename, kind, size, modified_at, last_scan,
              status, local_attempts, parser_version, associated_video_rel_path)
            VALUES('\(relPath)', '\(parentDir)', 'base', '\(kind.rawValue)', 10, 0, \(lastScan),
              '\(status)', \(attempts), \(pv), \(av));
            """))
    }

    private func intQuery(_ conn: CatalogConnection, _ sql: String) -> Int {
        var v = 0
        conn.query(sql) { v = Int(CatalogConnection.columnDouble($0, 0)) }
        return v
    }

    private func textQuery(_ conn: CatalogConnection, _ sql: String) -> String? {
        var v: String?
        conn.query(sql) { v = CatalogConnection.columnText($0, 0) }
        return v
    }

    // MARK: - value cache

    func testValueCacheRoundTripReplaceAndClear() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)

        XCTAssertTrue(repo.replaceSidecarValueCache(relPath: "a.nfo", fields: [
            .title: "\"Movie\"", .genres: "[\"Drama\"]"
        ]))
        XCTAssertEqual(repo.sidecarValueCache(relPath: "a.nfo"), [
            .title: "\"Movie\"", .genres: "[\"Drama\"]"
        ])

        // Replace with a smaller set fully supersedes (delete + insert).
        XCTAssertTrue(repo.replaceSidecarValueCache(relPath: "a.nfo", fields: [.title: "\"New\""]))
        XCTAssertEqual(repo.sidecarValueCache(relPath: "a.nfo"), [.title: "\"New\""])

        // Empty fields leaves no rows.
        XCTAssertTrue(repo.replaceSidecarValueCache(relPath: "a.nfo", fields: [:]))
        XCTAssertTrue(repo.sidecarValueCache(relPath: "a.nfo").isEmpty)

        XCTAssertTrue(repo.replaceSidecarValueCache(relPath: "a.nfo", fields: [.overview: "\"p\""]))
        XCTAssertTrue(repo.clearSidecarValueCache(relPath: "a.nfo"))
        XCTAssertTrue(repo.sidecarValueCache(relPath: "a.nfo").isEmpty)
    }

    // MARK: - status / processing-state mutations

    func testMarkSidecarProcessedStampsAndResetsAttempts() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)
        seedSidecar(conn, relPath: "m.nfo", status: "pending", attempts: 2)

        XCTAssertTrue(repo.markSidecarProcessed(
            relPath: "m.nfo", status: "parsed", fingerprint: "fp1",
            associatedItemID: "f:m.mkv", parserVersion: 7
        ))
        XCTAssertEqual(repo.sidecarStatus(relPath: "m.nfo"), "parsed")
        XCTAssertEqual(textQuery(conn, "SELECT processed_fingerprint FROM local_metadata_files WHERE rel_path='m.nfo';"), "fp1")
        XCTAssertEqual(textQuery(conn, "SELECT associated_item_id FROM local_metadata_files WHERE rel_path='m.nfo';"), "f:m.mkv")
        XCTAssertEqual(intQuery(conn, "SELECT parser_version FROM local_metadata_files WHERE rel_path='m.nfo';"), 7)
        XCTAssertEqual(intQuery(conn, "SELECT local_attempts FROM local_metadata_files WHERE rel_path='m.nfo';"), 0)
    }

    func testMarkTransientFailureIncrementsAttempts() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)
        seedSidecar(conn, relPath: "m.nfo", status: "pending", attempts: 1)

        XCTAssertTrue(repo.markSidecarTransientFailure(relPath: "m.nfo"))
        XCTAssertEqual(intQuery(conn, "SELECT local_attempts FROM local_metadata_files WHERE rel_path='m.nfo';"), 2)
        XCTAssertEqual(repo.sidecarStatus(relPath: "m.nfo"), "pending", "transient failure stays pending")
    }

    func testResetPendingAttemptsOnlyClearsPending() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)
        seedSidecar(conn, relPath: "p.nfo", status: "pending", attempts: 2)
        seedSidecar(conn, relPath: "d.nfo", status: "parsed", attempts: 3)

        repo.resetPendingLocalMetadataAttempts()
        XCTAssertEqual(intQuery(conn, "SELECT local_attempts FROM local_metadata_files WHERE rel_path='p.nfo';"), 0)
        XCTAssertEqual(intQuery(conn, "SELECT local_attempts FROM local_metadata_files WHERE rel_path='d.nfo';"), 3,
                       "a terminal sidecar's attempts are untouched")
    }

    // MARK: - parser-upgrade reread (once)

    func testParserUpgradeMarksStaleTerminalRowsPendingOnce() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)
        // Stale terminal (older version) + NULL-version terminal → both reread.
        seedSidecar(conn, relPath: "old.nfo", status: "parsed", attempts: 1, parserVersion: 1)
        seedSidecar(conn, relPath: "null.nfo", status: "malformed", attempts: 2, parserVersion: nil)
        // Current-version terminal + already-pending → untouched.
        seedSidecar(conn, relPath: "cur.nfo", status: "parsed", attempts: 0, parserVersion: 5)
        seedSidecar(conn, relPath: "pend.nfo", status: "pending", attempts: 0, parserVersion: 1)

        let changed = repo.markSidecarsPendingForParserUpgrade(to: 5)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(repo.sidecarStatus(relPath: "old.nfo"), "pending")
        XCTAssertEqual(repo.sidecarStatus(relPath: "null.nfo"), "pending")
        XCTAssertEqual(repo.sidecarStatus(relPath: "cur.nfo"), "parsed")
        XCTAssertNil(textQuery(conn, "SELECT processed_fingerprint FROM local_metadata_files WHERE rel_path='old.nfo' AND processed_fingerprint IS NOT NULL;"))
        XCTAssertEqual(intQuery(conn, "SELECT local_attempts FROM local_metadata_files WHERE rel_path='old.nfo';"), 0)

        // Idempotent: a second upgrade to the same version rereads nothing more.
        XCTAssertEqual(repo.markSidecarsPendingForParserUpgrade(to: 5), 0)
    }

    // MARK: - pending slice ordering / bounds

    func testPendingSliceOrderingAttemptCapAndLimit() {
        let (conn, url) = openConnection()
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = LocalMetadataRepository(connection: conn)
        seedSidecar(conn, relPath: "b.nfo", lastScan: 2, status: "pending", attempts: 0)
        seedSidecar(conn, relPath: "a.nfo", lastScan: 1, status: "pending", attempts: 0)
        seedSidecar(conn, relPath: "c.nfo", lastScan: 1, status: "pending", attempts: 0)
        seedSidecar(conn, relPath: "capped.nfo", lastScan: 0, status: "pending", attempts: 3) // >= maxAttempts
        seedSidecar(conn, relPath: "done.nfo", lastScan: 0, status: "parsed", attempts: 0)

        let files = repo.pendingLocalMetadataFiles(limit: 10, maxAttempts: 3)
        // Ordered by (last_scan, rel_path); capped/terminal excluded.
        XCTAssertEqual(files.map(\.relPath), ["a.nfo", "c.nfo", "b.nfo"])

        let limited = repo.pendingLocalMetadataFiles(limit: 2, maxAttempts: 3)
        XCTAssertEqual(limited.map(\.relPath), ["a.nfo", "c.nfo"])

        XCTAssertTrue(repo.pendingLocalMetadataFiles(limit: 0, maxAttempts: 3).isEmpty)
    }
}
