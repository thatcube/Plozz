import Foundation
import SQLite3
import CoreNetworking

/// The actor-confined SQLite handle for one share catalog: it owns `open`, `close`,
/// pragmas, schema-migration execution, and the low-level prepare/bind/step
/// helpers. It is created and held privately by `ShareCatalogStore` (the single
/// serialization boundary) and is **never** exposed outside it or used
/// concurrently — every call is made under the store actor's isolation. Extracting
/// it keeps the raw SQLite mechanics out of `ShareCatalogStore`'s query/orchestration
/// responsibilities without introducing a second connection or actor.
final class CatalogConnection {
    private let url: URL
    private(set) var db: OpaquePointer?
    private var didOpen = false

    /// SQLite wants a destructor sentinel for transient (copied) bound text; not
    /// exported into Swift, so reconstruct it.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open / schema

    /// Idempotently opens the database and migrates its schema to `user_version = 3`
    /// inside one `BEGIN IMMEDIATE` transaction. `legacyMetadataMigration` runs
    /// inside that same transaction at the exact point the original monolithic
    /// `ensureOpen` ran it (after the v1 enrichment schema, before the Step-3 v2
    /// sidecar schema); returning `false` aborts and rolls back. Returns `true`
    /// **only** on the single call where the schema was just committed ready, so the
    /// owning store can run its one-time post-open projection repairs exactly once.
    func ensureOpen(legacyMetadataMigration: (CatalogConnection) -> Bool) -> Bool {
        guard !didOpen else { return false }
        didOpen = true
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            PlozzLog.boot("share.catalog OPEN FAILED file=\(url.lastPathComponent)")
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = handle
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("PRAGMA synchronous=NORMAL;")
        guard exec("BEGIN IMMEDIATE;") else {
            sqlite3_close(handle)
            db = nil
            didOpen = false
            return false
        }
        var migrationSucceeded = true
        func apply(_ sql: String) {
            if !exec(sql) { migrationSucceeded = false }
        }
        apply("""
        CREATE TABLE IF NOT EXISTS assets(
            rel_path    TEXT PRIMARY KEY,
            basename    TEXT NOT NULL,
            size        INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            first_seen_at REAL NOT NULL,
            last_scan   INTEGER NOT NULL,
            kind        TEXT NOT NULL,
            library     TEXT NOT NULL,
            title       TEXT NOT NULL,
            sort_title  TEXT NOT NULL,
            year        INTEGER,
            series_title TEXT,
            series_key  TEXT,
            season      INTEGER,
            episode     INTEGER,
            movie_key   TEXT,
            movie_title_key TEXT,
            movie_group_key TEXT
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_assets_lib ON assets(library, kind);")
        apply("CREATE INDEX IF NOT EXISTS idx_assets_series ON assets(series_key, season, episode);")
        apply("CREATE INDEX IF NOT EXISTS idx_assets_added ON assets(first_seen_at DESC);")
        // Covers the Movies grid query (WHERE library, kind ORDER BY sort_title) so
        // the sort is index-provided instead of a per-page temp B-tree sort.
        apply("CREATE INDEX IF NOT EXISTS idx_assets_movies_sort ON assets(library, kind, sort_title);")
        apply("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
        // Per-logical-item enrichment (resolved at scan time by ShareEnricher and
        // persisted): external ids for merge/ratings/Trakt, plus overview + artwork
        // URLs so detail/cards are rich without a live lookup. Keyed by the item's
        // catalog id ("f:<relpath>" for movies, "series:<key>" for series).
        apply("""
        CREATE TABLE IF NOT EXISTS enrichment(
            item_id     TEXT PRIMARY KEY,
            provider_ids_json TEXT,
            overview    TEXT,
            genres_json TEXT,
            runtime     REAL,
            poster_url  TEXT,
            backdrop_url TEXT,
            logo_url    TEXT,
            enriched_at REAL NOT NULL,
            enrich_version INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            title TEXT
        );
        """)
        // Migration: bounded-retry attempt counter (added after first ship). Guarded
        // so it runs at most once; `exec` ignores the "duplicate column" error too.
        if !hasColumn(table: "enrichment", column: "attempts") {
            apply("ALTER TABLE enrichment ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;")
        }
        // Migration: the resolved canonical title (e.g. "Avatar: The Last Airbender"),
        // applied over a generic folder-derived display title at READ time — durable
        // across re-scans (which overwrite `assets.series_title`), unlike a direct
        // assets mutation.
        if !hasColumn(table: "enrichment", column: "title") {
            apply("ALTER TABLE enrichment ADD COLUMN title TEXT;")
        }
        // Source-addressable metadata lives beside the unchanged flat winning
        // projection. The old table stays readable through this schema transition.
        apply("""
        CREATE TABLE IF NOT EXISTS metadata_values(
            item_id TEXT NOT NULL,
            field TEXT NOT NULL,
            source TEXT NOT NULL,
            value_json TEXT NOT NULL,
            source_url TEXT,
            source_revision TEXT,
            refreshed_at REAL,
            expires_at REAL,
            PRIMARY KEY(item_id, field, source)
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_metadata_values_item ON metadata_values(item_id);")
        apply("""
        CREATE TABLE IF NOT EXISTS metadata_enrichment_state(
            item_id TEXT PRIMARY KEY,
            local_version INTEGER,
            external_version INTEGER,
            local_attempts INTEGER NOT NULL DEFAULT 0,
            external_attempts INTEGER NOT NULL DEFAULT 0
        );
        """)
        // Migration: movie grouping key (added with within-share version dedup). NULL
        // for rows indexed before it existed; a classifier-version reparse backfills
        // it, and grouped queries `COALESCE(movie_key, rel_path)` so pre-reparse rows
        // each stand alone rather than collapsing into one NULL bucket.
        if !hasColumn(table: "assets", column: "movie_key") {
            apply("ALTER TABLE assets ADD COLUMN movie_key TEXT;")
        }
        if !hasColumn(table: "assets", column: "movie_title_key") {
            apply("ALTER TABLE assets ADD COLUMN movie_title_key TEXT;")
        }
        if !hasColumn(table: "assets", column: "movie_group_key") {
            apply("ALTER TABLE assets ADD COLUMN movie_group_key TEXT;")
        }
        apply("CREATE INDEX IF NOT EXISTS idx_assets_movie_key ON assets(library, kind, movie_key);")
        apply("CREATE INDEX IF NOT EXISTS idx_assets_movie_group ON assets(library, kind, movie_group_key);")
        apply("CREATE INDEX IF NOT EXISTS idx_assets_movie_key_direct ON assets(movie_key);")
        apply("CREATE INDEX IF NOT EXISTS idx_assets_movie_group_direct ON assets(movie_group_key);")
        apply("""
        CREATE TABLE IF NOT EXISTS movie_alias(
            alias_id  TEXT PRIMARY KEY,
            group_key TEXT NOT NULL
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_movie_alias_group ON movie_alias(group_key);")
        // Durable series reconciliation: maps a redundant series key (e.g. a typo'd
        // folder "peaky-blinder") to a canonical one ("peaky-blinders") once BOTH
        // were proven the same show by a shared authoritative external id. Applied at
        // upsert so a re-scan can't undo the merge.
        apply("""
        CREATE TABLE IF NOT EXISTS series_merge(
            alias_key     TEXT PRIMARY KEY,
            canonical_key TEXT NOT NULL
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_series_merge_canonical ON series_merge(canonical_key);")
        apply("""
        CREATE INDEX IF NOT EXISTS idx_assets_movie_logical_sort
        ON assets(
          library, kind,
          COALESCE(movie_group_key, movie_key, rel_path),
          sort_title
        );
        """)
        if migrationSucceeded, !legacyMetadataMigration(self) {
            migrationSucceeded = false
        }

        // MARK: Step 3 — NFO / explicit-id schema (v2)
        //
        // Transport-neutral sidecar + explicit-id inventory. Only listing facts —
        // no parsed field data lives here; `local_metadata_file_values` below holds
        // the per-sidecar parse CACHE. All additive/nullable so an existing v1
        // catalog upgrades in place without discarding anything.
        apply("""
        CREATE TABLE IF NOT EXISTS local_metadata_files(
            rel_path TEXT PRIMARY KEY,
            parent_dir TEXT NOT NULL,
            basename TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            stable_file_id TEXT,
            strong_etag TEXT,
            change_token TEXT,
            associated_video_rel_path TEXT,
            last_scan INTEGER NOT NULL,
            fingerprint TEXT,
            scan_generation_bound INTEGER NOT NULL DEFAULT 0,
            processed_fingerprint TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            local_attempts INTEGER NOT NULL DEFAULT 0,
            parser_version INTEGER,
            associated_item_id TEXT,
            updated_at REAL
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_local_metadata_files_status ON local_metadata_files(status);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_metadata_files_parent ON local_metadata_files(parent_dir);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_metadata_files_item ON local_metadata_files(associated_item_id);")
        // Per-sidecar parsed-value CACHE, keyed by sidecar path + field. Lets an
        // association recompute (e.g. after a SIBLING sidecar is deleted) reuse an
        // unchanged file's already-parsed values without rereading it.
        apply("""
        CREATE TABLE IF NOT EXISTS local_metadata_file_values(
            rel_path TEXT NOT NULL,
            field TEXT NOT NULL,
            value_json TEXT NOT NULL,
            PRIMARY KEY(rel_path, field)
        );
        """)
        if !hasColumn(table: "assets", column: "metadata_root") {
            apply("ALTER TABLE assets ADD COLUMN metadata_root TEXT;")
        }
        if !hasColumn(table: "assets", column: "explicit_ids_json") {
            apply("ALTER TABLE assets ADD COLUMN explicit_ids_json TEXT;")
        }
        // MARK: Step 4 — local artwork inventory / associations (v3)
        //
        // This remains additive: v2 catalog content and external enrichment lanes
        // are intentionally untouched. Probe state is present for the later bounded
        // ImageIO worker, but listing-only scans leave every row pending.
        apply("""
        CREATE TABLE IF NOT EXISTS local_artwork_files(
            rel_path TEXT PRIMARY KEY,
            catalog_artwork_id TEXT,
            parent_dir TEXT NOT NULL,
            basename TEXT NOT NULL,
            extension TEXT NOT NULL,
            name_stem TEXT NOT NULL,
            name_role TEXT,
            explicit_media_stem TEXT,
            numbered_alternative INTEGER,
            language TEXT,
            season INTEGER,
            is_specials INTEGER NOT NULL DEFAULT 0,
            folder_kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            stable_file_id TEXT,
            strong_etag TEXT,
            change_token TEXT,
            fingerprint TEXT NOT NULL,
            scan_generation_bound INTEGER NOT NULL DEFAULT 0,
            last_scan INTEGER NOT NULL,
            probe_status TEXT NOT NULL DEFAULT 'pending',
            probe_version INTEGER,
            processed_fingerprint TEXT,
            width INTEGER,
            height INTEGER,
            content_type TEXT,
            probe_attempts INTEGER NOT NULL DEFAULT 0,
            updated_at REAL
        );
        """)
        if !hasColumn(table: "local_artwork_files", column: "catalog_artwork_id") {
            apply("ALTER TABLE local_artwork_files ADD COLUMN catalog_artwork_id TEXT;")
        }
        apply("CREATE UNIQUE INDEX IF NOT EXISTS idx_local_artwork_files_catalog_id ON local_artwork_files(catalog_artwork_id);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_artwork_files_status ON local_artwork_files(probe_status, last_scan);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_artwork_files_parent ON local_artwork_files(parent_dir);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_artwork_files_scan ON local_artwork_files(last_scan);")
        apply("""
        CREATE TABLE IF NOT EXISTS local_artwork_associations(
            item_id TEXT NOT NULL,
            placement TEXT NOT NULL,
            artwork_rel_path TEXT NOT NULL,
            rank INTEGER NOT NULL,
            selected_order INTEGER NOT NULL,
            PRIMARY KEY(item_id, placement, artwork_rel_path)
        );
        """)
        apply("CREATE INDEX IF NOT EXISTS idx_local_artwork_associations_item ON local_artwork_associations(item_id, placement, selected_order);")
        apply("CREATE INDEX IF NOT EXISTS idx_local_artwork_associations_path ON local_artwork_associations(artwork_rel_path);")
        apply("PRAGMA user_version=3;")
        if migrationSucceeded, exec("COMMIT;") {
            return true
        }
        _ = exec("ROLLBACK;")
        PlozzLog.boot("share.catalog MIGRATION FAILED file=\(url.lastPathComponent)")
        return false
    }

    // MARK: - Small SQLite helpers

    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Whether `table` already has `column` — drives one-shot column migrations.
    /// `table`/`column` are compile-time literals at every call site, so the
    /// interpolation into the PRAGMA carries no injection risk.
    func hasColumn(table: String, column: String) -> Bool {
        var found = false
        query("PRAGMA table_info(\(table));") { stmt in
            if CatalogConnection.columnText(stmt, 1) == column { found = true }
        }
        return found
    }

    func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    /// Run a parameterized write statement with a binder; finalizes cleanly.
    func runUpdate(_ sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    static func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, transient)
    }
    static func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }
    static func bindOptInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, idx, Int64(value)) } else { sqlite3_bind_null(stmt, idx) }
    }
    static func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
    static func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double {
        sqlite3_column_double(stmt, idx)
    }
    static func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, idx))
    }
}
