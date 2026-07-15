import Foundation

struct SearchIndexSchemaMigrator {
    static let currentVersion = 2

    func migrate(_ connection: SearchSQLiteConnection) throws {
        try connection.exec("PRAGMA foreign_keys=ON;")
        try connection.exec("PRAGMA journal_mode=WAL;")
        try connection.exec("PRAGMA synchronous=NORMAL;")

        let version = try connection.scalarInt("PRAGMA user_version;")
        guard version <= Self.currentVersion else {
            throw SearchIndexStoreError.unsupportedSchema(version)
        }
        switch version {
        case 0:
            try createVersion2(connection)
        case 1:
            try migrateVersion1ToVersion2(connection)
        case 2:
            try ensureVersion2Objects(connection)
        default:
            throw SearchIndexStoreError.unsupportedSchema(version)
        }
    }

    private func createVersion2(_ connection: SearchSQLiteConnection) throws {
        try connection.transaction {
            try createDocumentsAndVectors(connection)
            try createSyncState(connection)
            try connection.exec("PRAGMA user_version=2;")
        }
    }

    private func migrateVersion1ToVersion2(
        _ connection: SearchSQLiteConnection
    ) throws {
        // Version 1 lacked kind-partitioned sync cursors. Documents/vectors remain
        // compatible; only resumable scan state is discarded.
        try connection.transaction {
            try connection.exec("DROP TABLE IF EXISTS sync_state;")
            try createDocumentsAndVectors(connection)
            try connection.exec("""
            UPDATE documents
            SET library_id=COALESCE(library_id, ''), scan_generation=0;
            """)
            try createSyncState(connection)
            try connection.exec("PRAGMA user_version=2;")
        }
    }

    private func ensureVersion2Objects(_ connection: SearchSQLiteConnection) throws {
        try createDocumentsAndVectors(connection)
        try connection.exec("""
        UPDATE documents SET library_id='' WHERE library_id IS NULL;
        """)
        try createSyncState(connection)
    }

    private func createDocumentsAndVectors(
        _ connection: SearchSQLiteConnection
    ) throws {
        try connection.exec("""
        CREATE TABLE IF NOT EXISTS documents(
          source_key TEXT PRIMARY KEY,
          account_id TEXT NOT NULL,
          provider_user_key TEXT NOT NULL,
          item_id TEXT NOT NULL,
          library_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          title_normalized TEXT NOT NULL,
          parent_title_normalized TEXT,
          metadata_text TEXT NOT NULL,
          media_item_json BLOB NOT NULL,
          content_hash TEXT NOT NULL,
          scan_generation INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_search_documents_scope
          ON documents(account_id, provider_user_key, library_id, kind);
        CREATE TABLE IF NOT EXISTS vectors(
          source_key TEXT NOT NULL REFERENCES documents(source_key) ON DELETE CASCADE,
          segment INTEGER NOT NULL,
          language TEXT NOT NULL,
          revision INTEGER NOT NULL,
          dimension INTEGER NOT NULL,
          storage_format TEXT NOT NULL,
          vector_data BLOB NOT NULL,
          PRIMARY KEY(source_key, segment)
        );
        CREATE INDEX IF NOT EXISTS idx_search_vectors_model
          ON vectors(language, revision, dimension);
        """)
    }

    private func createSyncState(_ connection: SearchSQLiteConnection) throws {
        try connection.exec("""
        CREATE TABLE IF NOT EXISTS sync_state(
          account_id TEXT NOT NULL,
          provider_user_key TEXT NOT NULL,
          library_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          cursor BLOB,
          last_full_scan_at REAL,
          scan_generation INTEGER NOT NULL,
          scan_active INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(account_id, provider_user_key, library_id, kind)
        );
        """)
    }
}
