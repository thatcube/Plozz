import XCTest
import SQLite3
import CoreModels
@testable import SearchIndexKit

final class SearchIndexMigrationTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSQLiteFailureClassificationPreservesRetryability() {
        XCTAssertEqual(
            SearchSQLiteConnection.failure(code: SQLITE_BUSY, message: "busy"),
            .busy("busy")
        )
        XCTAssertEqual(
            SearchSQLiteConnection.failure(code: SQLITE_LOCKED, message: "locked"),
            .locked("locked")
        )
        XCTAssertEqual(
            SearchSQLiteConnection.failure(code: SQLITE_NOTADB, message: "bad"),
            .notDatabase("bad")
        )
    }

    func testInjectedBusyDoesNotDeleteDatabase() async throws {
        let directory = try tempDirectory()
        let databaseURL = directory.appendingPathComponent("search-index-profile.sqlite")
        try Data("keep me".utf8).write(to: databaseURL)
        let store = LocalSearchIndex(
            scopeKey: "profile",
            directory: directory,
            connectionFactory: { _ in
                throw SearchIndexStoreError.sqlite(.busy("injected"))
            }
        )

        do {
            _ = try await store.documentCount()
            XCTFail("Expected busy error")
        } catch {
            XCTAssertEqual(error as? SearchIndexStoreError, .sqlite(.busy("injected")))
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), Data("keep me".utf8))
    }

    func testFutureSchemaPreservesFileAndSurfacesError() async throws {
        let directory = try tempDirectory()
        let databaseURL = directory.appendingPathComponent("search-index-profile.sqlite")
        let connection = try SearchSQLiteConnection(url: databaseURL)
        try connection.exec("PRAGMA user_version=99;")
        connection.close()
        let before = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber
        let store = LocalSearchIndex(scopeKey: "profile", directory: directory)

        do {
            _ = try await store.documentCount()
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? SearchIndexStoreError, .unsupportedSchema(99))
        }
        let after = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber
        XCTAssertEqual(after, before)
    }

    func testVersionOneMigrationPreservesDocumentsAndVectors() async throws {
        let directory = try tempDirectory()
        let databaseURL = directory.appendingPathComponent("search-index-profile.sqlite")
        let connection = try SearchSQLiteConnection(url: databaseURL)
        try connection.exec("""
        CREATE TABLE documents(
          source_key TEXT PRIMARY KEY, account_id TEXT NOT NULL,
          provider_user_key TEXT NOT NULL, item_id TEXT NOT NULL,
          library_id TEXT, kind TEXT NOT NULL, title_normalized TEXT NOT NULL,
          parent_title_normalized TEXT, metadata_text TEXT NOT NULL,
          media_item_json BLOB NOT NULL, content_hash TEXT NOT NULL,
          provider_updated_at REAL, scan_generation INTEGER NOT NULL
        );
        CREATE TABLE vectors(
          source_key TEXT NOT NULL REFERENCES documents(source_key) ON DELETE CASCADE,
          segment INTEGER NOT NULL, language TEXT NOT NULL, revision INTEGER NOT NULL,
          dimension INTEGER NOT NULL, storage_format TEXT NOT NULL,
          vector_data BLOB NOT NULL, PRIMARY KEY(source_key, segment)
        );
        CREATE TABLE sync_state(
          account_id TEXT NOT NULL, provider_user_key TEXT NOT NULL,
          library_id TEXT NOT NULL, cursor BLOB, last_delta_at REAL,
          last_full_scan_at REAL, scan_generation INTEGER NOT NULL,
          scan_active INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(account_id, provider_user_key, library_id)
        );
        PRAGMA user_version=1;
        """)
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            overview: "A restaurant story.",
            libraryID: "shows"
        ).taggingSource("account")
        let itemData = try JSONEncoder().encode(item)
        try connection.execute("""
        INSERT INTO documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
        """) { statement in
            connection.bindText("account:episode", to: statement, index: 1)
            connection.bindText("account", to: statement, index: 2)
            connection.bindText("user", to: statement, index: 3)
            connection.bindText("episode", to: statement, index: 4)
            connection.bindText("shows", to: statement, index: 5)
            connection.bindText("episode", to: statement, index: 6)
            connection.bindText("episode", to: statement, index: 7)
            sqlite3_bind_null(statement, 8)
            connection.bindText("Episode. A restaurant story.", to: statement, index: 9)
            connection.bindBlob(itemData, to: statement, index: 10)
            connection.bindText("hash", to: statement, index: 11)
            sqlite3_bind_null(statement, 12)
            sqlite3_bind_int64(statement, 13, 1)
        }
        let vector = try VectorCodec.encode([1, 0, 0], format: .float16)
        try connection.execute("INSERT INTO vectors VALUES(?,?,?,?,?,?,?);") { statement in
            connection.bindText("account:episode", to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, 0)
            connection.bindText("en", to: statement, index: 3)
            sqlite3_bind_int64(statement, 4, 1)
            sqlite3_bind_int64(statement, 5, 3)
            connection.bindText("float16", to: statement, index: 6)
            connection.bindBlob(vector, to: statement, index: 7)
        }
        try connection.exec("""
        INSERT INTO documents
        SELECT 'account:orphan', account_id, provider_user_key, 'orphan',
               library_id, kind, 'orphan', parent_title_normalized,
               metadata_text, media_item_json, 'orphan-hash',
               provider_updated_at, 9
        FROM documents WHERE source_key='account:episode';
        INSERT INTO vectors
        SELECT 'account:orphan', segment, language, revision, dimension,
               storage_format, vector_data
        FROM vectors WHERE source_key='account:episode';
        """)
        connection.close()

        let store = LocalSearchIndex(scopeKey: "profile", directory: directory)
        let count = try await store.documentCount()
        XCTAssertEqual(count, 2)
        let matches = try await store.search(LocalSearchRequest(
            queryText: "restaurant",
            queryVector: [1, 0, 0],
            descriptor: EmbeddingModelDescriptor(
                language: .english,
                revision: 1,
                dimension: 3
            ),
            limit: 1
        ))
        XCTAssertEqual(matches.map(\.sourceKey), ["account:episode"])

        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "account",
            providerUserKey: "user",
            libraryID: "shows",
            kind: .episode
        )
        let checkpoint = try await store.beginOrResumeFullScan(
            scope: scope,
            writeToken: token
        )
        let survivor = SearchDocumentBuilder().document(
            for: item,
            accountID: "account",
            providerUserKey: "user"
        )
        try await store.upsert(
            document: survivor,
            embeddings: nil,
            scanGeneration: checkpoint.generation,
            writeToken: token
        )
        try await store.finishFullScan(
            checkpoint: checkpoint,
            writeToken: token,
            expectedTotalCount: 1
        )
        let afterPrune = try await store.documentCount()
        XCTAssertEqual(afterPrune, 1)
    }
}
