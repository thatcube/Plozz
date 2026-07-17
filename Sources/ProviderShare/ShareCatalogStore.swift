import Foundation
import SQLite3
import CoreModels
import CoreNetworking

/// SQLite-backed catalog for one share — the persistent index that lets a share
/// answer `latest()`, `search()`, and browse **Movies / TV Shows / Anime**
/// instantly, without a live SMB walk on the Home hot path.
///
/// Why SQLite (not JSON): low memory on tvOS (reads only what a query needs, not
/// the whole file), indexed search, relational series→season→episode grouping,
/// and incremental scan upserts. Uses the system `libsqlite3` (no dependency).
///
/// **Location & durability:** `Library/Caches/Plozz/share-catalog-<accountKey>.sqlite`,
/// mirroring `ShareWatchStore` — `Application Support` does NOT survive relaunch on
/// tvOS (see `ShareWatchStore.defaultDirectory()`), whereas `Library/Caches`
/// persists across launches and is only purged under genuine storage pressure. The
/// catalog is therefore a **rebuildable cache**: if purged, the next scan rebuilds
/// it. Personal state (watch/resume) never lives here.
///
/// An `actor` so the single SQLite connection is only ever touched from one task
/// at a time (the connection is used single-threaded).
actor ShareCatalogStore {
    enum EnrichmentSaveFailurePoint: Sendable, Equatable {
        case afterDerivedCatalogMutations
    }

    private let url: URL
    private let enrichmentSaveFailurePoint: EnrichmentSaveFailurePoint?
    private var db: OpaquePointer?
    private var didOpen = false
    private var normalizedMetadataReady = false
    /// Cached "does ANY local (NFO/filename) metadata_values row exist" check —
    /// avoids a real query on every read-path call (`withLocalOverlay`/grid sort
    /// join) for the common no-NFO catalog, where it must add negligible
    /// overhead over the existing no-NFO behavior. `nil` until first computed;
    /// flips true immediately on a successful local write, never flips back to
    /// false speculatively (a stale `true` after the last sidecar is removed just
    /// costs one harmless empty-result query, not a correctness issue).
    private var hasAnyLocalMetadataCache: Bool?
    private var activeScanGeneration: UUID?
    private var pendingMergedSeriesLocalRepairs = Set<String>()

    // SQLite wants a destructor sentinel for transient (copied) bound text; not
    // exported into Swift, so reconstruct it.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Bounded catalog writes keep the actor cooperative with Home/grid/search
    /// reads while a large share is scanning.
    private static let writeChunkSize = 200

    private struct MovieGroupingRow: Sendable {
        var relPath: String
        var movieKey: String
        var titleKey: String
        var year: Int?
        var existingGroup: String?
    }
    private struct MovieGroupAssignment: Sendable {
        var relPath: String
        var group: String
    }
    private struct MovieAlias: Sendable {
        var id: String
        var group: String
    }
    private struct MovieGroupingPlan: Sendable {
        var assignments: [MovieGroupAssignment]
        var aliases: [MovieAlias]
    }

    /// - Parameters:
    ///   - accountKey: stable per-share id (`server.id`) — names the DB file so two
    ///     shares keep separate catalogs. Shares the key with `ShareWatchStore`.
    ///   - directory: container dir (defaults to `Library/Caches/Plozz`).
    init(
        accountKey: String,
        directory: URL? = nil,
        enrichmentSaveFailurePoint: EnrichmentSaveFailurePoint? = nil
    ) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("share-catalog-\(Self.sanitize(accountKey)).sqlite")
        self.enrichmentSaveFailurePoint = enrichmentSaveFailurePoint
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open / schema

    private func ensureOpen() {
        guard !didOpen else { return }
        didOpen = true
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            PlozzLog.boot("share.catalog OPEN FAILED file=\(url.lastPathComponent)")
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("PRAGMA synchronous=NORMAL;")
        guard exec("BEGIN IMMEDIATE;") else {
            sqlite3_close(handle)
            db = nil
            didOpen = false
            return
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
        if migrationSucceeded, !metadataMigrationComplete() {
            if !migrateLegacyEnrichmentMetadata()
                || !exec("""
                    INSERT INTO meta(key, value) VALUES('metadata_values_migrated_v1', '1')
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                    """) {
                migrationSucceeded = false
            }
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
        apply("PRAGMA user_version=2;")
        if migrationSucceeded, exec("COMMIT;") {
            normalizedMetadataReady = true
            repairAllLocalMetadataProjections()
            repairFilenameProviderIDs()
            return
        }
        _ = exec("ROLLBACK;")
        PlozzLog.boot("share.catalog MIGRATION FAILED file=\(url.lastPathComponent)")
    }

    // MARK: - Scan write path

    /// Insert or update a batch of discovered assets under one scan id. Preserves
    /// `first_seen_at` for rows already present (so "date added" = first discovery,
    /// never a re-scan), and refreshes size/mtime/parse/library. Idempotent.
    func activateScanGeneration(_ generation: UUID) {
        activeScanGeneration = generation
    }

    func invalidateScanGeneration() {
        activeScanGeneration = nil
    }

    func nextScanID(for generation: UUID) -> Int64? {
        guard activeScanGeneration == generation else { return nil }
        let current = Int64(meta("scan_counter") ?? "0") ?? 0
        let next = current + 1
        setMeta("scan_counter", String(next))
        return next
    }

    func upsert(
        _ assets: [CatalogAsset],
        scanID: Int64,
        now: Date = Date(),
        scanGeneration: UUID? = nil
    ) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil, !assets.isEmpty else { return }
        let started = Date()
        var slowestChunkMs = 0
        let sql = """
        INSERT INTO assets
          (rel_path, basename, size, modified_at, first_seen_at, last_scan,
           kind, library, title, sort_title, year, series_title, series_key, season, episode,
           movie_key, movie_title_key, metadata_root, explicit_ids_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          basename=excluded.basename, size=excluded.size, modified_at=excluded.modified_at,
          last_scan=excluded.last_scan, kind=excluded.kind, library=excluded.library,
          title=excluded.title, sort_title=excluded.sort_title, year=excluded.year,
          series_title=excluded.series_title, series_key=excluded.series_key,
          season=excluded.season, episode=excluded.episode, movie_key=excluded.movie_key,
          movie_title_key=excluded.movie_title_key, metadata_root=excluded.metadata_root,
          explicit_ids_json=excluded.explicit_ids_json,
          movie_group_key=CASE
            WHEN assets.movie_key=excluded.movie_key
             AND assets.movie_title_key=excluded.movie_title_key
            THEN assets.movie_group_key
            ELSE NULL
          END;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        // Preload the series-merge alias map once so a reconciled typo key stays
        // folded across re-scans without a per-row lookup in the hot write loop.
        let seriesAliases = seriesMergeMap()

        var index = 0
        while index < assets.count {
            guard admits(scanGeneration) else { return }
            let end = min(index + Self.writeChunkSize, assets.count)
            let chunkStarted = Date()
            exec("BEGIN IMMEDIATE;")
            for a in assets[index..<end] {
                sqlite3_reset(stmt)
                bindText(stmt, 1, a.relPath)
                bindText(stmt, 2, a.basename)
                sqlite3_bind_int64(stmt, 3, a.size)
                sqlite3_bind_double(stmt, 4, a.modifiedAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 6, scanID)
                bindText(stmt, 7, a.kind.rawValue)
                bindText(stmt, 8, a.library.rawValue)
                bindText(stmt, 9, a.title)
                let libraryTitle = a.kind == .episode ? (a.seriesTitle ?? a.title) : a.title
                bindText(stmt, 10, ShareCatalogID.sortTitle(from: libraryTitle))
                bindOptInt(stmt, 11, a.year)
                bindOptText(stmt, 12, a.seriesTitle)
                bindOptText(stmt, 13, a.seriesKey.map { Self.resolveAlias($0, in: seriesAliases) })
                bindOptInt(stmt, 14, a.season)
                bindOptInt(stmt, 15, a.episode)
                bindOptText(stmt, 16, a.movieKey)
                bindOptText(stmt, 17, a.movieTitleKey)
                bindOptText(stmt, 18, a.metadataRoot)
                bindOptText(stmt, 19, a.explicitProviderIDs.isEmpty ? nil : encodeJSON(a.explicitProviderIDs))
                _ = sqlite3_step(stmt)
            }
            exec("COMMIT;")
            slowestChunkMs = max(slowestChunkMs, Int(Date().timeIntervalSince(chunkStarted) * 1_000))
            index = end
            if index < assets.count { await Task.yield() }
        }
        if slowestChunkMs >= 20 {
            PlozzLog.boot(
                "share.catalog slow upsert files=\(assets.count) total=\(Int(Date().timeIntervalSince(started) * 1_000))ms maxChunk=\(slowestChunkMs)ms"
            )
        }
    }

    /// Rebuild persisted logical movie groups after a CLEAN full scan. Files with
    /// the same normalized title and a release-year spread of at most one are
    /// versions of one movie (metadata commonly differs by festival/theatrical
    /// year); distant remakes remain separate. Existing group ids win so adding a
    /// version later does not churn watch-state or deep-link ids.
    func rebuildMovieGroups(scanGeneration: UUID? = nil) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        let started = Date()

        var rows: [MovieGroupingRow] = []
        query("""
        SELECT rel_path, movie_key, movie_title_key, year, movie_group_key
        FROM assets
        WHERE library='movies' AND kind='movie'
          AND movie_key IS NOT NULL AND movie_title_key IS NOT NULL;
        """) { stmt in
            guard let relPath = self.columnText(stmt, 0),
                  let movieKey = self.columnText(stmt, 1),
                  let titleKey = self.columnText(stmt, 2) else { return }
            rows.append(MovieGroupingRow(
                relPath: relPath,
                movieKey: movieKey,
                titleKey: titleKey,
                year: self.columnOptInt(stmt, 3),
                existingGroup: self.columnText(stmt, 4)
            ))
        }

        // Sorting/grouping is pure CPU work. Run it off-actor so a grid/search/
        // detail query can use the SQLite connection while a large catalog is
        // computing assignments.
        let computeStarted = Date()
        let plan: MovieGroupingPlan = await Task.detached(priority: .utility) {
            var assignments: [MovieGroupAssignment] = []
            var aliases: [MovieAlias] = []
            for titleRows in Dictionary(grouping: rows, by: \.titleKey).values {
                let known = titleRows.filter { $0.year != nil }.sorted {
                    if $0.year != $1.year { return ($0.year ?? 0) < ($1.year ?? 0) }
                    return $0.relPath < $1.relPath
                }
                var clusters: [[MovieGroupingRow]] = []
                for row in known {
                    if let last = clusters.indices.last,
                       let firstYear = clusters[last].first?.year,
                       let year = row.year,
                       year - firstYear <= 1 {
                        clusters[last].append(row)
                    } else {
                        clusters.append([row])
                    }
                }

                let unknown = titleRows.filter { $0.year == nil }
                if !unknown.isEmpty {
                    if clusters.count == 1 {
                        clusters[0].append(contentsOf: unknown)
                    } else {
                        clusters.append(unknown)
                    }
                }

                for cluster in clusters {
                    let existing = cluster.compactMap(\.existingGroup).sorted().first
                    let fallback = cluster.max {
                        if $0.year != $1.year { return ($0.year ?? 0) < ($1.year ?? 0) }
                        return $0.movieKey > $1.movieKey
                    }?.movieKey
                    guard let group = existing ?? fallback else { continue }
                    // Re-scans usually produce zero writes. Only changed/new group
                    // members enter the bounded SQLite update phase.
                    assignments.append(contentsOf: cluster.compactMap { row in
                        row.existingGroup == group ? nil : MovieGroupAssignment(relPath: row.relPath, group: group)
                    })
                    for row in cluster {
                        aliases.append(MovieAlias(id: row.movieKey, group: group))
                        aliases.append(MovieAlias(id: ShareCatalogID.file(row.relPath), group: group))
                    }
                }
            }
            return MovieGroupingPlan(assignments: assignments, aliases: aliases)
        }.value
        guard admits(scanGeneration) else { return }
        let computeMs = Int(Date().timeIntervalSince(computeStarted) * 1_000)

        await persistMovieAliases(plan.aliases, scanGeneration: scanGeneration)
        guard admits(scanGeneration) else { return }

        guard !plan.assignments.isEmpty else {
            PlozzLog.boot(
                "share.catalog regroup rows=\(rows.count) changed=0 compute=\(computeMs)ms total=\(Int(Date().timeIntervalSince(started) * 1_000))ms"
            )
            return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE assets SET movie_group_key=? WHERE rel_path=?;", -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        var index = 0
        var slowestChunkMs = 0
        while index < plan.assignments.count {
            guard admits(scanGeneration) else { return }
            let end = min(index + Self.writeChunkSize, plan.assignments.count)
            let chunkStarted = Date()
            exec("BEGIN IMMEDIATE;")
            for assignment in plan.assignments[index..<end] {
                sqlite3_reset(stmt)
                bindText(stmt, 1, assignment.group)
                bindText(stmt, 2, assignment.relPath)
                _ = sqlite3_step(stmt)
            }
            exec("COMMIT;")
            slowestChunkMs = max(slowestChunkMs, Int(Date().timeIntervalSince(chunkStarted) * 1_000))
            index = end
            if index < plan.assignments.count { await Task.yield() }
        }
        PlozzLog.boot(
            "share.catalog regroup rows=\(rows.count) changed=\(plan.assignments.count) compute=\(computeMs)ms total=\(Int(Date().timeIntervalSince(started) * 1_000))ms maxChunk=\(slowestChunkMs)ms"
        )
    }

    /// Capture aliases from the pre-prune catalog so a removed movie version's
    /// legacy file id still resolves to the surviving logical group.
    func preserveMovieAliasesBeforePrune(scanGeneration: UUID? = nil) {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        exec("BEGIN IMMEDIATE;")
        exec("""
        INSERT INTO movie_alias(alias_id, group_key)
        SELECT movie_key, COALESCE(movie_group_key, movie_key)
        FROM assets
        WHERE library='movies' AND kind='movie' AND movie_key IS NOT NULL
        ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
        """)
        exec("""
        INSERT INTO movie_alias(alias_id, group_key)
        SELECT 'f:' || rel_path, COALESCE(movie_group_key, movie_key)
        FROM assets
        WHERE library='movies' AND kind='movie' AND movie_key IS NOT NULL
        ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
        """)
        exec("COMMIT;")
    }

    private func persistMovieAliases(
        _ aliases: [MovieAlias],
        scanGeneration: UUID?
    ) async {
        guard admits(scanGeneration), !aliases.isEmpty else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO movie_alias(alias_id, group_key) VALUES(?,?)
        ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
        """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var index = 0
        while index < aliases.count {
            guard admits(scanGeneration) else { return }
            let end = min(index + Self.writeChunkSize, aliases.count)
            exec("BEGIN IMMEDIATE;")
            for alias in aliases[index..<end] {
                sqlite3_reset(stmt)
                bindText(stmt, 1, alias.id)
                bindText(stmt, 2, alias.group)
                _ = sqlite3_step(stmt)
            }
            exec("COMMIT;")
            index = end
            if index < aliases.count { await Task.yield() }
        }
    }

    /// Delete rows not seen by `scanID` — assets removed from the share since the
    /// last full walk. Only call after a scan that fully completed (no cancel), so
    /// a partial walk can't wipe still-present content.
    func pruneNotSeen(inScan scanID: Int64, scanGeneration: UUID? = nil) {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM assets WHERE last_scan <> ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, scanID)
        _ = sqlite3_step(stmt)
    }

    func setMeta(_ key: String, _ value: String, scanGeneration: UUID? = nil) {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        _ = sqlite3_step(stmt)
    }

    func meta(_ key: String) -> String? {
        ensureOpen()
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    private func admits(_ scanGeneration: UUID?) -> Bool {
        guard let scanGeneration else { return true }
        return activeScanGeneration == scanGeneration
    }

    // MARK: - Local NFO / explicit-id sidecar inventory (Step 3)

    /// Bounded retry cap for a sidecar stuck on a TRANSIENT transport failure —
    /// mirrors `maxEnrichAttempts`'s "bounded, never retried forever" posture.
    static let maxLocalAttempts = 3

    /// One sidecar row read back for the local metadata worker (either the
    /// scheduled slice's next batch, or the urgent opened-item lookup).
    struct PendingLocalMetadataFile: Sendable, Equatable {
        var relPath: String
        var parentDir: String
        var kind: LocalSidecarKind
        var size: Int64
        var associatedVideoRelPath: String?
        var processedItemID: String?
        var fingerprint: String?
        /// A weak transport gave no change-detection facts — this file rereads
        /// once per successful full scan rather than on every scheduler slice.
        var scanGenerationBound: Bool
        var status: String
        var attempts: Int
    }

    /// Insert/update the sidecar inventory discovered by THIS scan's BFS listing.
    /// A row whose fingerprint is UNCHANGED keeps its `status`/`processed_fingerprint`/
    /// `local_attempts`/`associated_item_id` (no rereading an unchanged file); a
    /// changed fingerprint (or a weak-transport row, which has none) resets to
    /// `pending` so the local worker revisits it.
    func upsertSidecars(
        _ sidecars: [LocalSidecarCandidate],
        scanID: Int64,
        now: Date = Date(),
        scanGeneration: UUID? = nil
    ) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil, !sidecars.isEmpty else { return }
        let sql = """
        INSERT INTO local_metadata_files(
          rel_path, parent_dir, basename, kind, size, modified_at,
          stable_file_id, strong_etag, change_token, associated_video_rel_path,
          last_scan, fingerprint, scan_generation_bound, processed_fingerprint,
          status, local_attempts, updated_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,'pending',0,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          parent_dir=excluded.parent_dir, basename=excluded.basename, kind=excluded.kind,
          size=excluded.size, modified_at=excluded.modified_at,
          stable_file_id=excluded.stable_file_id, strong_etag=excluded.strong_etag,
          change_token=excluded.change_token,
          associated_video_rel_path=excluded.associated_video_rel_path,
          last_scan=excluded.last_scan, fingerprint=excluded.fingerprint,
          scan_generation_bound=excluded.scan_generation_bound,
          status=CASE
            WHEN excluded.scan_generation_bound=1 THEN 'pending'
            WHEN local_metadata_files.fingerprint IS NOT excluded.fingerprint THEN 'pending'
            ELSE local_metadata_files.status
          END,
          processed_fingerprint=CASE
            WHEN excluded.scan_generation_bound=1 THEN NULL
            WHEN local_metadata_files.fingerprint IS NOT excluded.fingerprint THEN NULL
            ELSE local_metadata_files.processed_fingerprint
          END,
          local_attempts=CASE
            WHEN excluded.scan_generation_bound=1 THEN 0
            WHEN local_metadata_files.fingerprint IS NOT excluded.fingerprint THEN 0
            ELSE local_metadata_files.local_attempts
          END,
          updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var index = 0
        while index < sidecars.count {
            guard admits(scanGeneration) else { return }
            let end = min(index + Self.writeChunkSize, sidecars.count)
            var affectedItemIDs = Set<String>()
            exec("BEGIN IMMEDIATE;")
            for sidecar in sidecars[index..<end] {
                let fingerprintEvaluation = ShareSidecarFingerprintPolicy.evaluate(
                    strongETag: sidecar.strongETag, changeToken: sidecar.changeToken,
                    stableFileID: sidecar.stableFileID, modifiedAt: sidecar.modifiedAt,
                    size: sidecar.size
                )
                let fingerprint = fingerprintEvaluation.fingerprint
                let weakTransport = fingerprintEvaluation.scanGenerationBound
                var hadPriorRow = false
                var priorFingerprint: String?
                var priorItemID: String?
                query("SELECT fingerprint, associated_item_id FROM local_metadata_files WHERE rel_path=?;",
                      bind: { self.bindText($0, 1, sidecar.relPath) }) { existing in
                    hadPriorRow = true
                    priorFingerprint = self.columnText(existing, 0)
                    priorItemID = self.columnText(existing, 1)
                }
                if hadPriorRow, weakTransport || priorFingerprint != fingerprint {
                    if let priorItemID { affectedItemIDs.insert(priorItemID) }
                }
                sqlite3_reset(stmt)
                bindText(stmt, 1, sidecar.relPath)
                bindText(stmt, 2, sidecar.parentDir)
                bindText(stmt, 3, sidecar.basename)
                bindText(stmt, 4, sidecar.kind.rawValue)
                sqlite3_bind_int64(stmt, 5, sidecar.size)
                sqlite3_bind_double(stmt, 6, sidecar.modifiedAt.timeIntervalSince1970)
                bindOptText(stmt, 7, sidecar.stableFileID)
                bindOptText(stmt, 8, sidecar.strongETag)
                bindOptText(stmt, 9, sidecar.changeToken)
                bindOptText(stmt, 10, sidecar.associatedVideoRelPath)
                sqlite3_bind_int64(stmt, 11, scanID)
                bindOptText(stmt, 12, fingerprint)
                sqlite3_bind_int64(stmt, 13, weakTransport ? 1 : 0)
                sqlite3_bind_double(stmt, 14, now.timeIntervalSince1970)
                _ = sqlite3_step(stmt)
            }
            exec("COMMIT;")
            for itemID in affectedItemIDs {
                _ = materializeCachedLocalMetadata(itemID: itemID)
            }
            index = end
            if index < sidecars.count { await Task.yield() }
        }
    }

    /// Drop sidecar inventory/cache rows not seen by `scanID` (a clean full scan
    /// only — mirrors `pruneNotSeen`), and remove any `localNFO` metadata
    /// candidate whose winning sidecar disappeared, so external/filename/legacy
    /// fallback resurfaces immediately at the next read (the read-time overlay
    /// means no separate "recompute" step is needed).
    func pruneSidecarsNotSeen(inScan scanID: Int64, scanGeneration: UUID? = nil) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        var stalePaths: [String] = []
        var affectedItemIDs = Set<String>()
        query("SELECT rel_path, associated_item_id FROM local_metadata_files WHERE last_scan <> ?;",
              bind: { sqlite3_bind_int64($0, 1, scanID) }) { stmt in
            if let p = self.columnText(stmt, 0) { stalePaths.append(p) }
            if let itemID = self.columnText(stmt, 1) { affectedItemIDs.insert(itemID) }
        }
        guard !stalePaths.isEmpty else { return }
        guard exec("BEGIN IMMEDIATE;") else { return }
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM local_metadata_files WHERE last_scan <> ?;", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_int64(del, 1, scanID)
            _ = sqlite3_step(del)
            sqlite3_finalize(del)
        }
        let placeholders = Array(repeating: "?", count: stalePaths.count).joined(separator: ",")
        var delValues: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM local_metadata_file_values WHERE rel_path IN (\(placeholders));", -1, &delValues, nil) == SQLITE_OK {
            for (offset, path) in stalePaths.enumerated() { bindText(delValues, Int32(offset + 1), path) }
            _ = sqlite3_step(delValues)
            sqlite3_finalize(delValues)
        }
        exec("COMMIT;")
        for itemID in affectedItemIDs {
            _ = materializeCachedLocalMetadata(itemID: itemID)
        }
    }

    private func materializePendingLocalMetadataFile(_ stmt: OpaquePointer?) -> PendingLocalMetadataFile? {
        guard let relPath = columnText(stmt, 0),
              let parentDir = columnText(stmt, 1),
              let kindRaw = columnText(stmt, 2),
              let kind = LocalSidecarKind(rawValue: kindRaw) else { return nil }
        return PendingLocalMetadataFile(
            relPath: relPath, parentDir: parentDir, kind: kind,
            size: sqlite3_column_int64(stmt, 3),
            associatedVideoRelPath: columnText(stmt, 4),
            processedItemID: columnText(stmt, 5),
            fingerprint: columnText(stmt, 6),
            scanGenerationBound: sqlite3_column_int64(stmt, 7) != 0,
            status: columnText(stmt, 8) ?? "pending",
            attempts: Int(sqlite3_column_int64(stmt, 9))
        )
    }

    private static let pendingLocalMetadataFileColumns =
        "rel_path, parent_dir, kind, size, associated_video_rel_path, associated_item_id, fingerprint, scan_generation_bound, status, local_attempts"

    /// The next bounded slice of pending sidecars for the scheduled background
    /// pass, oldest-scanned first.
    func pendingLocalMetadataFiles(limit: Int) -> [PendingLocalMetadataFile] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [PendingLocalMetadataFile] = []
        query("""
        SELECT \(Self.pendingLocalMetadataFileColumns) FROM local_metadata_files
        WHERE status='pending' AND local_attempts < ?
        ORDER BY last_scan, rel_path LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(Self.maxLocalAttempts))
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            if let file = self.materializePendingLocalMetadataFile(stmt) { out.append(file) }
        }
        return out
    }

    /// Whether ANY pending/retryable sidecar would associate with `itemID` — the
    /// urgent opened-item path's signal to promote local work ahead of external
    /// fast-track. Discovers the association even before the batch worker has
    /// ever visited this item (see `candidateSidecars`).
    func pendingLocalMetadataFile(forItemID itemID: String) -> PendingLocalMetadataFile? {
        candidateSidecars(forItemID: itemID).first {
            $0.attempts < Self.maxLocalAttempts
                && $0.status == "pending"
        }
    }

    func sidecarStatus(relPath: String) -> String? {
        var status: String?
        query("SELECT status FROM local_metadata_files WHERE rel_path=?;",
              bind: { self.bindText($0, 1, relPath) }) { stmt in status = self.columnText(stmt, 0) }
        return status
    }

    /// Every sidecar row that WOULD associate with `itemID` under the
    /// deterministic association rules (movie stem > movie.nfo fill-missing;
    /// tvshow.nfo by metadata root; episode stem), regardless of current
    /// processing status. Used both to discover urgent work and (by the worker)
    /// to combine cached per-sidecar values before writing one winning candidate.
    func candidateSidecars(forItemID itemID: String) -> [PendingLocalMetadataFile] {
        ensureOpen()
        guard db != nil else { return [] }
        var out: [PendingLocalMetadataFile] = []
        var members: [ShareLocalMetadataMember] = []
        if let relPath = ShareCatalogID.relPath(forFileID: itemID) {
            var isMovie = false
            query("SELECT kind FROM assets WHERE rel_path=?;", bind: { self.bindText($0, 1, relPath) }) { stmt in
                isMovie = self.columnText(stmt, 0) == "movie"
            }
            let parentDir = (relPath as NSString).deletingLastPathComponent
            members = [.init(
                relPath: relPath,
                isMovie: isMovie,
                genericRepresentativeRelPath: isMovie
                    ? unambiguousMovieGroupRepresentative(inDirectory: parentDir)
                    : nil
            )]
        } else if let mkey = ShareCatalogID.movieKey(forMovieID: itemID) {
            let groupKey = resolvedMovieGroupKey(mkey)
            query("""
            SELECT rel_path FROM assets
            WHERE COALESCE(movie_group_key, movie_key)=? AND library='movies' AND kind='movie';
            """, bind: { self.bindText($0, 1, groupKey) }) { stmt in
                guard let relPath = self.columnText(stmt, 0) else { return }
                let parentDir = (relPath as NSString).deletingLastPathComponent
                members.append(.init(
                    relPath: relPath,
                    isMovie: true,
                    genericRepresentativeRelPath: self.unambiguousMovieGroupRepresentative(
                        inDirectory: parentDir
                    )
                ))
            }
        }

        var roots: Set<String> = []
        if ShareCatalogID.isSeries(itemID), let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            query("SELECT DISTINCT metadata_root FROM assets WHERE series_key=? AND metadata_root IS NOT NULL;",
                  bind: { self.bindText($0, 1, key) }) { stmt in
                if let r = self.columnText(stmt, 0) { roots.insert(r) }
            }
        }
        for lookup in ShareLocalMetadataAssociationPolicy.lookups(
            members: members,
            seriesRoots: roots
        ) {
            let predicate: String
            let value: String
            switch lookup {
            case .exactVideo(let relPath):
                predicate = "associated_video_rel_path=? AND kind IN ('movieStem','episodeStem')"
                value = relPath
            case .genericMovie(let parentDir):
                predicate = "parent_dir=? AND kind='movieGeneric'"
                value = parentDir
            case .series(let parentDir):
                predicate = "parent_dir=? AND kind='series'"
                value = parentDir
            }
            query("""
            SELECT \(Self.pendingLocalMetadataFileColumns)
            FROM local_metadata_files WHERE \(predicate);
            """, bind: { self.bindText($0, 1, value) }) { stmt in
                if let file = self.materializePendingLocalMetadataFile(stmt) {
                    out.append(file)
                }
            }
        }

        var seen = Set<String>()
        return out.filter { seen.insert($0.relPath).inserted }
    }

    /// Movie files directly inside `dir` form exactly ONE logical group — the
    /// requirement for a `movie.nfo` there to apply — return that group's
    /// representative (`MIN(rel_path)`) file, else `nil` (no movies, or more than
    /// one distinct group: ambiguous).
    func unambiguousMovieGroupRepresentative(inDirectory dir: String) -> String? {
        ensureOpen()
        guard db != nil else { return nil }
        var repsByGroup: [String: String] = [:]
        query("SELECT rel_path, movie_key, movie_group_key FROM assets WHERE library='movies' AND kind='movie';") { stmt in
            guard let relPath = self.columnText(stmt, 0),
                  (relPath as NSString).deletingLastPathComponent == dir else { return }
            let key = self.columnText(stmt, 2) ?? self.columnText(stmt, 1) ?? relPath
            if let existing = repsByGroup[key], relPath >= existing { return }
            repsByGroup[key] = relPath
        }
        guard repsByGroup.count == 1 else { return nil }
        return repsByGroup.values.first
    }

    /// The movie group's representative (`MIN(rel_path)`) file for ANY member's
    /// relPath — the id local movie writes always target (mirrors the external
    /// enrichment convention, which projection reads only via this same id).
    func movieGroupRepresentativeRelPath(forMemberRelPath relPath: String) -> String {
        ensureOpen()
        guard db != nil else { return relPath }
        var groupKey: String?
        query("SELECT COALESCE(movie_group_key, movie_key) FROM assets WHERE rel_path=? AND library='movies' AND kind='movie';",
              bind: { self.bindText($0, 1, relPath) }) { stmt in groupKey = self.columnText(stmt, 0) }
        guard let groupKey else { return relPath }
        var rep: String?
        query("""
        SELECT MIN(rel_path) FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=? AND library='movies' AND kind='movie';
        """, bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
        return rep ?? relPath
    }

    /// The series whose persisted `metadata_root` equals `root` — how a
    /// `tvshow.nfo` resolves to its series.
    func seriesKey(forMetadataRoot root: String) -> String? {
        ensureOpen()
        guard db != nil else { return nil }
        var key: String?
        query("SELECT series_key FROM assets WHERE metadata_root=? AND series_key IS NOT NULL LIMIT 1;",
              bind: { self.bindText($0, 1, root) }) { stmt in key = self.columnText(stmt, 0) }
        return key
    }

    /// Reconcile sidecar-to-item associations after a clean scan changes the
    /// asset topology. Parsed caches move (or stop applying) without a reread;
    /// a formerly ambiguous, never-parsed sidecar becomes pending when its
    /// directory is now unambiguous.
    func reconcileSidecarAssociations(scanGeneration: UUID? = nil) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        var files: [PendingLocalMetadataFile] = []
        query("SELECT \(Self.pendingLocalMetadataFileColumns) FROM local_metadata_files ORDER BY rel_path;") { stmt in
            if let file = self.materializePendingLocalMetadataFile(stmt) {
                files.append(file)
            }
        }
        for file in files {
            guard admits(scanGeneration) else { return }
            let facts = localMetadataAssociationFacts(for: file)
            let desiredItemID = ShareLocalMetadataAssociationPolicy.itemID(
                for: file.kind,
                associatedVideoRelPath: file.associatedVideoRelPath,
                facts: facts
            )
            let cache = sidecarValueCache(relPath: file.relPath)
            guard let plan = ShareLocalMetadataAssociationPolicy.reassociationPlan(
                priorItemID: file.processedItemID,
                desiredItemID: desiredItemID,
                priorStatus: file.status,
                cacheIsEmpty: cache.isEmpty
            ) else { continue }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                UPDATE local_metadata_files
                SET associated_item_id=?, status=?,
                    processed_fingerprint=CASE WHEN ?=1 THEN NULL ELSE processed_fingerprint END
                WHERE rel_path=?;
                """, -1, &stmt, nil) == SQLITE_OK {
                bindOptText(stmt, 1, desiredItemID)
                bindText(stmt, 2, plan.status)
                sqlite3_bind_int64(stmt, 3, plan.clearProcessedFingerprint ? 1 : 0)
                bindText(stmt, 4, file.relPath)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            for itemID in Set([file.processedItemID, desiredItemID].compactMap { $0 }) {
                _ = materializeCachedLocalMetadata(itemID: itemID)
            }
            await Task.yield()
        }
    }

    func localMetadataAssociationFacts(
        for file: PendingLocalMetadataFile
    ) -> ShareLocalMetadataAssociationFacts {
        ensureOpen()
        guard db != nil else { return .init() }
        var facts = ShareLocalMetadataAssociationFacts()
        if let relPath = file.associatedVideoRelPath {
            var kind: String?
            query("SELECT kind FROM assets WHERE rel_path=? LIMIT 1;",
                  bind: { self.bindText($0, 1, relPath) }) { stmt in
                kind = self.columnText(stmt, 0)
            }
            facts.associatedVideoExists = switch file.kind {
            case .episodeStem:
                kind == "episode"
            default:
                kind != nil
            }
            if kind == "movie" {
                facts.movieRepresentativeRelPath = movieGroupRepresentativeRelPath(
                    forMemberRelPath: relPath
                )
            }
        }
        facts.genericRepresentativeRelPath = unambiguousMovieGroupRepresentative(
            inDirectory: file.parentDir
        )
        facts.seriesKey = seriesKey(forMetadataRoot: file.parentDir)
        return facts
    }

    /// Persist ONE sidecar's raw parsed field cache (`local_metadata_file_values`)
    /// so a later reassociation (a sibling sidecar removed) can reuse an
    /// unchanged file's values without rereading it.
    func writeSidecarValueCache(relPath: String, fields: [MetadataField: String]) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        var del: OpaquePointer?
        var ok = sqlite3_prepare_v2(db, "DELETE FROM local_metadata_file_values WHERE rel_path=?;", -1, &del, nil) == SQLITE_OK
        if ok {
            bindText(del, 1, relPath)
            ok = sqlite3_step(del) == SQLITE_DONE
        }
        sqlite3_finalize(del)
        if ok, !fields.isEmpty {
            var stmt: OpaquePointer?
            ok = sqlite3_prepare_v2(db, """
            INSERT INTO local_metadata_file_values(rel_path, field, value_json) VALUES(?,?,?);
            """, -1, &stmt, nil) == SQLITE_OK
            if ok {
                for (field, json) in fields {
                    sqlite3_reset(stmt)
                    bindText(stmt, 1, relPath)
                    bindText(stmt, 2, field.rawValue)
                    bindText(stmt, 3, json)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { ok = false; break }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard ok, exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        return true
    }

    @discardableResult
    func clearSidecarValueCache(relPath: String) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM local_metadata_file_values WHERE rel_path=?;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, relPath)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// The cached parsed field values for one sidecar (`nil` when never cached).
    func sidecarValueCache(relPath: String) -> [MetadataField: String] {
        ensureOpen()
        guard db != nil else { return [:] }
        var out: [MetadataField: String] = [:]
        query("SELECT field, value_json FROM local_metadata_file_values WHERE rel_path=?;",
              bind: { self.bindText($0, 1, relPath) }) { stmt in
            guard let field = self.columnText(stmt, 0), let json = self.columnText(stmt, 1) else { return }
            out[MetadataField(rawValue: field)] = json
        }
        return out
    }

    /// Rebuild the complete local-NFO lane for an item from currently associated,
    /// successfully parsed sidecars. Replacing the whole lane lets removed fields
    /// and deleted/invalid sidecars reveal surviving generic or external fallback.
    @discardableResult
    func materializeCachedLocalMetadata(itemID: String) -> Bool {
        ensureOpen()
        guard db != nil, normalizedMetadataReady else { return false }
        let sidecars = candidateSidecars(forItemID: itemID)
            .filter { $0.status == "parsed" }
            .map { file in
            ShareLocalMetadataSidecarValues(
                relPath: file.relPath,
                kind: file.kind,
                status: file.status,
                fingerprint: file.fingerprint,
                values: sidecarValueCache(relPath: file.relPath)
            )
        }
        return replaceLocalNFOMetadata(
            itemID: itemID,
            candidates: ShareLocalMetadataWinnerResolver.resolve(sidecars)
        )
    }

    private func repairAllLocalMetadataProjections() {
        guard db != nil, normalizedMetadataReady else { return }
        var parsedSidecars: [ShareLocalMetadataParsedSidecar] = []
        query("""
        SELECT rel_path, fingerprint, associated_item_id
        FROM local_metadata_files
        WHERE status='parsed';
        """) { stmt in
            guard let relPath = self.columnText(stmt, 0) else { return }
            parsedSidecars.append(.init(
                sourceRevision: ShareLocalMetadataWinnerResolver.sourceRevision(
                    relPath: relPath,
                    fingerprint: self.columnText(stmt, 1)
                ),
                itemID: self.columnText(stmt, 2)
            ))
        }
        var storedValues: [ShareLocalMetadataStoredValue] = []
        query("""
        SELECT item_id, source_revision FROM metadata_values
        WHERE source='localNFO';
        """) { stmt in
            guard let itemID = self.columnText(stmt, 0) else { return }
            storedValues.append(.init(
                itemID: itemID,
                sourceRevision: self.columnText(stmt, 1)
            ))
        }
        var currentLocalVersions: [String: Int] = [:]
        query("""
        SELECT item_id, local_version FROM metadata_enrichment_state
        WHERE local_version IS NOT NULL;
        """) { stmt in
            guard let itemID = self.columnText(stmt, 0) else { return }
            currentLocalVersions[itemID] = Int(sqlite3_column_int64(stmt, 1))
        }
        let itemIDs = ShareLocalMetadataRepairPlanner.itemIDsToRepair(
            parsedSidecars: parsedSidecars,
            storedValues: storedValues,
            localVersions: currentLocalVersions,
            currentVersion: ShareLocalMetadataEnricher.version
        )
        for itemID in itemIDs {
            if materializeCachedLocalMetadata(itemID: itemID) {
                _ = writeLocalEnrichmentState(
                    itemID: itemID,
                    version: ShareLocalMetadataEnricher.version,
                    attempts: 0
                )
            }
        }
    }

    /// Mark a sidecar's TERMINAL processing outcome for its current fingerprint
    /// (parsed / malformed / oversized / ambiguous). Unchanged terminal files are
    /// never rereleased. `associatedItemID` is recorded even for a
    /// malformed/ambiguous outcome (nil there) so the urgent path can tell "no
    /// association" from "not processed yet".
    @discardableResult
    func markSidecarProcessed(
        relPath: String,
        status: String,
        fingerprint: String?,
        associatedItemID: String?,
        now: Date = Date()
    ) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        UPDATE local_metadata_files SET
          status=?, processed_fingerprint=?, associated_item_id=?, local_attempts=0, updated_at=?
        WHERE rel_path=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, status)
        bindOptText(stmt, 2, fingerprint)
        bindOptText(stmt, 3, associatedItemID)
        sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
        bindText(stmt, 5, relPath)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Record a TRANSIENT transport failure: stays `pending`, bumps the bounded
    /// retry counter, never fabricates a successful local version.
    @discardableResult
    func markSidecarTransientFailure(relPath: String) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        UPDATE local_metadata_files SET local_attempts = local_attempts + 1 WHERE rel_path=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, relPath)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func resetPendingLocalMetadataAttempts() {
        ensureOpen()
        guard db != nil else { return }
        _ = exec("UPDATE local_metadata_files SET local_attempts=0 WHERE status='pending';")
    }

    /// Replace ONLY the local-sourced (`localNFO`/`filename`) `metadata_values`
    /// rows for the fields this write touches, for ONE item — never external/
    /// legacy rows, and never a local field NOT included here (so one sidecar's
    /// write can't blank another sidecar's still-valid field). `sourceURL` is
    /// always persisted `NULL` — the local-provenance-privacy invariant.
    @discardableResult
    func writeLocalMetadata(
        itemID: String,
        candidates: [ShareLocalMetadataFieldCandidate],
        now: Date = Date()
    ) -> Bool {
        ensureOpen()
        guard db != nil, normalizedMetadataReady else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        var ok = true
        let candidatesBySource = Dictionary(grouping: candidates, by: \.source)
        for (source, sourceCandidates) in candidatesBySource where ok {
            let fields = Array(Set(sourceCandidates.map(\.field.rawValue)))
            let placeholders = Array(repeating: "?", count: fields.count).joined(separator: ",")
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                DELETE FROM metadata_values
                WHERE item_id=? AND source=? AND field IN (\(placeholders));
                """, -1, &del, nil) == SQLITE_OK {
                bindText(del, 1, itemID)
                bindText(del, 2, source.rawValue)
                for (offset, field) in fields.enumerated() {
                    bindText(del, Int32(offset + 3), field)
                }
                ok = sqlite3_step(del) == SQLITE_DONE
            } else {
                ok = false
            }
            sqlite3_finalize(del)
        }
        if ok, !candidates.isEmpty {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                INSERT INTO metadata_values(
                  item_id, field, source, value_json, source_url,
                  source_revision, refreshed_at, expires_at
                ) VALUES(?,?,?,?,NULL,?,?,NULL);
                """, -1, &stmt, nil) == SQLITE_OK {
                for candidate in candidates {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, itemID)
                    bindText(stmt, 2, candidate.field.rawValue)
                    bindText(stmt, 3, candidate.source.rawValue)
                    bindText(stmt, 4, candidate.valueJSON)
                    bindOptText(stmt, 5, candidate.sourceRevision)
                    sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { ok = false; break }
                }
            } else {
                ok = false
            }
            sqlite3_finalize(stmt)
        }
        guard ok, exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        if !candidates.isEmpty { hasAnyLocalMetadataCache = true }
        return true
    }

    private func replaceLocalNFOMetadata(
        itemID: String,
        candidates: [ShareLocalMetadataFieldCandidate],
        now: Date = Date()
    ) -> Bool {
        guard db != nil, normalizedMetadataReady else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        var ok = true
        var del: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "DELETE FROM metadata_values WHERE item_id=? AND source='localNFO';",
            -1,
            &del,
            nil
        ) == SQLITE_OK {
            bindText(del, 1, itemID)
            ok = sqlite3_step(del) == SQLITE_DONE
        } else {
            ok = false
        }
        sqlite3_finalize(del)
        if ok, !candidates.isEmpty {
            var stmt: OpaquePointer?
            ok = sqlite3_prepare_v2(db, """
                INSERT INTO metadata_values(
                  item_id, field, source, value_json, source_url,
                  source_revision, refreshed_at, expires_at
                ) VALUES(?,?,?,?,NULL,?,?,NULL);
                """, -1, &stmt, nil) == SQLITE_OK
            if ok {
                for candidate in candidates {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, itemID)
                    bindText(stmt, 2, candidate.field.rawValue)
                    bindText(stmt, 3, MetadataSource.localNFO.rawValue)
                    bindText(stmt, 4, candidate.valueJSON)
                    bindOptText(stmt, 5, candidate.sourceRevision)
                    sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        ok = false
                        break
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard ok, exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        hasAnyLocalMetadataCache = nil
        return true
    }

    /// Local scheduling state — read/written ONLY by the local worker, entirely
    /// independent of `external_version`/`external_attempts` (see
    /// `writeEnrichmentState` for the external side). A local write NEVER touches
    /// the external columns, so it can't make an already-current external state
    /// pending, and vice versa.
    @discardableResult
    func writeLocalEnrichmentState(itemID: String, version: Int, attempts: Int) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO metadata_enrichment_state(item_id, local_version, external_version, local_attempts, external_attempts)
        VALUES(?,?,NULL,?,0)
        ON CONFLICT(item_id) DO UPDATE SET
          local_version=excluded.local_version, local_attempts=excluded.local_attempts;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        sqlite3_bind_int64(stmt, 2, Int64(version))
        sqlite3_bind_int64(stmt, 3, Int64(attempts))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func localEnrichmentState(itemID: String) -> (version: Int, attempts: Int)? {
        ensureOpen()
        guard db != nil else { return nil }
        var out: (Int, Int)?
        query("SELECT local_version, local_attempts FROM metadata_enrichment_state WHERE item_id=?;",
              bind: { self.bindText($0, 1, itemID) }) { stmt in
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
            out = (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return out
    }

    func rematerializeLocalMetadataIfNeeded(itemID: String, version: Int) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        let state = localEnrichmentState(itemID: itemID)
        guard state?.version != version else { return false }
        var hasParsedSidecar = false
        query("""
        SELECT 1 FROM local_metadata_files
        WHERE associated_item_id=? AND status='parsed' LIMIT 1;
        """, bind: { self.bindText($0, 1, itemID) }) { _ in hasParsedSidecar = true }
        guard hasParsedSidecar,
              materializeCachedLocalMetadata(itemID: itemID),
              writeLocalEnrichmentState(itemID: itemID, version: version, attempts: 0) else {
            return false
        }
        return true
    }

    func rematerializeOutdatedLocalMetadata(version: Int, limit: Int) -> Int {
        ensureOpen()
        guard db != nil, limit > 0 else { return 0 }
        var itemIDs: [String] = []
        query("""
        SELECT DISTINCT f.associated_item_id
        FROM local_metadata_files f
        LEFT JOIN metadata_enrichment_state s ON s.item_id=f.associated_item_id
        WHERE f.associated_item_id IS NOT NULL AND f.status='parsed'
          AND (s.local_version IS NULL OR s.local_version<>?)
        ORDER BY f.associated_item_id
        LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(version))
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            if let itemID = self.columnText(stmt, 0) { itemIDs.append(itemID) }
        }
        var rematerialized = 0
        for itemID in itemIDs where rematerializeLocalMetadataIfNeeded(
            itemID: itemID,
            version: version
        ) {
            rematerialized += 1
        }
        return rematerialized
    }

    /// Persisted explicit filename/folder provider ids for an asset (populated by
    /// the scanner from pure path parsing — see `CatalogAsset.explicitProviderIDs`).
    func explicitProviderIDs(relPath: String) -> [String: String] {
        ensureOpen()
        guard db != nil else { return [:] }
        var json: String?
        query("SELECT explicit_ids_json FROM assets WHERE rel_path=?;",
              bind: { self.bindText($0, 1, relPath) }) { stmt in json = self.columnText(stmt, 0) }
        return decodeJSON([String: String].self, json) ?? [:]
    }

    /// Already-persisted local (NFO/filename) provider ids for `itemID`, seeded
    /// into the external resolver request so it can skip fuzzy title-based
    /// discovery where the provider supports exact-id resolution (see
    /// `ShareEnrichRequest.knownProviderIDs`).
    func localProviderIDs(forItemID itemID: String) -> [String: String] {
        ensureOpen()
        guard db != nil else { return [:] }
        var out: [String: String] = [:]
        query("""
        SELECT field, source, value_json FROM metadata_values
        WHERE item_id=? AND source IN ('localNFO','filename') AND field LIKE 'providerID.%'
        ORDER BY field, CASE WHEN source='localNFO' THEN 0 ELSE 1 END;
        """, bind: { self.bindText($0, 1, itemID) }) { stmt in
            guard let field = self.columnText(stmt, 0),
                  let json = self.columnText(stmt, 2),
                  let value = self.decodeJSON(String.self, json) else { return }
            let namespace = String(field.dropFirst("providerID.".count))
            if out[namespace] == nil { out[namespace] = value }
        }
        return out
    }

    /// Materializes `filename`-sourced provider-id candidates from persisted
    /// EXPLICIT path ids (`assets.explicit_ids_json`) into `metadata_values`, so
    /// filename/folder ids participate in the SAME priority-based read-time
    /// overlay as NFO ids (see `withLocalOverlay`). Pure computation over
    /// already-persisted asset data — no transport read. Called once per clean
    /// scan (see `ShareScanner.scan()`); idempotent, so a partial/skipped run
    /// (e.g. cancellation) simply catches up on the next clean scan.
    func materializeFilenameProviderIDs(scanGeneration: UUID? = nil) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil else { return }
        repairFilenameProviderIDs()
    }

    private func repairFilenameProviderIDs() {
        guard db != nil, normalizedMetadataReady else { return }
        var materialized: [String: [String: String]] = [:]
        // Movies: the explicit ids of the GROUP's representative file (or, when
        // absent there, the first member in deterministic path order) apply to
        // the group's representative item id.
        struct MovieRow { var relPath: String; var groupKey: String; var explicitJSON: String? }
        var movieRows: [MovieRow] = []
        query("""
        SELECT rel_path, COALESCE(movie_group_key, movie_key, rel_path), explicit_ids_json
        FROM assets WHERE library='movies' AND kind='movie' AND explicit_ids_json IS NOT NULL;
        """) { stmt in
            guard let relPath = self.columnText(stmt, 0), let group = self.columnText(stmt, 1) else { return }
            movieRows.append(MovieRow(relPath: relPath, groupKey: group, explicitJSON: self.columnText(stmt, 2)))
        }
        let movieRowsByGroup = Dictionary(grouping: movieRows, by: \.groupKey)
        for (groupKey, rows) in movieRowsByGroup {
            let ids = ShareExplicitIDPolicy.unambiguous(
                rows.compactMap { decodeJSON([String: String].self, $0.explicitJSON) }
            )
            guard !ids.isEmpty else { continue }
            var rep: String?
            query("""
            SELECT MIN(rel_path) FROM assets
            WHERE COALESCE(movie_group_key, movie_key)=? AND library='movies' AND kind='movie';
            """, bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
            let fallbackPath = rows.map(\.relPath).min() ?? groupKey
            materialized[ShareCatalogID.file(rep ?? fallbackPath)] = ids
        }

        // Series: the explicit ids of ANY episode's path (usually a shared show-
        // folder tag) apply to the series id.
        struct SeriesRow { var seriesKey: String; var explicitJSON: String? }
        var seriesRows: [SeriesRow] = []
        query("""
        SELECT series_key, explicit_ids_json FROM assets
        WHERE kind='episode' AND series_key IS NOT NULL AND explicit_ids_json IS NOT NULL;
        """) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            seriesRows.append(SeriesRow(seriesKey: key, explicitJSON: self.columnText(stmt, 1)))
        }
        for (seriesKey, rows) in Dictionary(grouping: seriesRows, by: \.seriesKey) {
            let ids = ShareExplicitIDPolicy.unambiguous(
                rows.compactMap { decodeJSON([String: String].self, $0.explicitJSON) }
            )
            guard !ids.isEmpty else { continue }
            materialized[ShareCatalogID.series(seriesKey)] = ids
        }

        guard exec("BEGIN IMMEDIATE;") else { return }
        var ok = exec("DELETE FROM metadata_values WHERE source='filename';")
        var stmt: OpaquePointer?
        if ok {
            ok = sqlite3_prepare_v2(db, """
                INSERT INTO metadata_values(
                  item_id, field, source, value_json, source_url,
                  source_revision, refreshed_at, expires_at
                ) VALUES(?,?,'filename',?,NULL,NULL,?,NULL);
                """, -1, &stmt, nil) == SQLITE_OK
        }
        if ok {
            let refreshedAt = Date().timeIntervalSince1970
            for itemID in materialized.keys.sorted() {
                for (namespace, value) in (materialized[itemID] ?? [:])
                    .sorted(by: { $0.key < $1.key }) {
                    guard let valueJSON = encodeJSON(value) else {
                        ok = false
                        break
                    }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, itemID)
                    bindText(stmt, 2, MetadataField.providerID(namespace).rawValue)
                    bindText(stmt, 3, valueJSON)
                    sqlite3_bind_double(stmt, 4, refreshedAt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        ok = false
                        break
                    }
                }
                if !ok { break }
            }
        }
        sqlite3_finalize(stmt)
        guard ok, exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return
        }
        hasAnyLocalMetadataCache = nil
    }

    // MARK: - Enrichment (scan-time metadata resolution, persisted)

    /// One logical item awaiting enrichment (movie or series). `itemID` is the
    /// catalog id the enrichment row is keyed by; `isAnime` reflects the current
    /// (best-effort) library classification so the resolver can route.
    struct PendingEnrichment: Sendable, Equatable {
        var itemID: String
        var title: String
        var year: Int?
        var isMovie: Bool
        var isAnime: Bool
        var discoveredAt: Date
    }

    /// Resolved metadata to persist for one logical item.
    struct EnrichmentRecord: Sendable, Equatable {
        var providerIDs: [String: String] = [:]
        var overview: String?
        var genres: [String] = []
        var runtime: TimeInterval?
        var posterURL: URL?
        var backdropURL: URL?
        var logoURL: URL?
        /// The resolved canonical show/movie title (e.g. "Avatar: The Last
        /// Airbender"), overlaid over a generic folder-derived display title at read
        /// time. Persisted in the `title` enrichment column so it survives re-scans.
        var title: String?
        var provenance = MetadataProvenance()

        static func sourced(
            providerIDs: [String: SourcedValue<String>] = [:],
            overview: SourcedValue<String>? = nil,
            genres: SourcedValue<[String]>? = nil,
            runtime: SourcedValue<TimeInterval>? = nil,
            posterURL: SourcedValue<URL>? = nil,
            backdropURL: SourcedValue<URL>? = nil,
            logoURL: SourcedValue<URL>? = nil,
            title: SourcedValue<String>? = nil
        ) -> EnrichmentRecord {
            var provenance = MetadataProvenance()
            for (namespace, value) in providerIDs {
                provenance[.providerID(namespace)] = value.attribution
            }
            provenance.set(overview, for: .overview)
            provenance.set(genres, for: .genres)
            provenance.set(runtime, for: .runtime)
            provenance.set(posterURL, for: .posterURL)
            provenance.set(backdropURL, for: .backdropURL)
            provenance.set(logoURL, for: .logoURL)
            provenance.set(title, for: .title)
            return EnrichmentRecord(
                providerIDs: providerIDs.mapValues(\.value),
                overview: overview?.value,
                genres: genres?.value ?? [],
                runtime: runtime?.value,
                posterURL: posterURL?.value,
                backdropURL: backdropURL?.value,
                logoURL: logoURL?.value,
                title: title?.value,
                provenance: provenance
            )
        }

        /// Whether this record carries anything worth showing/merging. An *unusable*
        /// result (no ids, overview, or artwork) is treated as a miss — usually a
        /// transient rate-limit/timeout — and is retried across passes rather than
        /// cached as a permanent blank.
        var isUsable: Bool {
            !providerIDs.isEmpty
                || (overview?.isEmpty == false)
                || posterURL != nil || backdropURL != nil || logoURL != nil
        }

        mutating func inferLegacyProvenanceForMissingFields() {
            let legacy = MetadataAttribution(source: .legacyUnknown)
            provenance.fillMissing(
                legacy,
                for: providerIDs.keys.map(MetadataField.providerID)
            )
            if overview?.isEmpty == false { provenance.fillMissing(legacy, for: [.overview]) }
            if !genres.isEmpty { provenance.fillMissing(legacy, for: [.genres]) }
            if runtime != nil { provenance.fillMissing(legacy, for: [.runtime]) }
            if posterURL != nil { provenance.fillMissing(legacy, for: [.posterURL]) }
            if backdropURL != nil { provenance.fillMissing(legacy, for: [.backdropURL]) }
            if logoURL != nil { provenance.fillMissing(legacy, for: [.logoURL]) }
            if title?.isEmpty == false { provenance.fillMissing(legacy, for: [.title]) }
        }
    }

    private struct PersistedMetadataValue {
        var field: MetadataField
        var valueJSON: String
        var attribution: MetadataAttribution
    }

    private func persistedMetadataValues(
        for record: EnrichmentRecord
    ) -> [PersistedMetadataValue] {
        var values: [PersistedMetadataValue] = []
        func append<T: Encodable>(_ value: T?, field: MetadataField) {
            guard let value,
                  let valueJSON = encodeJSON(value),
                  let attribution = record.provenance[field] else { return }
            values.append(PersistedMetadataValue(
                field: field,
                valueJSON: valueJSON,
                attribution: attribution
            ))
        }

        for (namespace, value) in record.providerIDs where !value.isEmpty {
            append(value, field: .providerID(namespace))
        }
        if record.overview?.isEmpty == false { append(record.overview, field: .overview) }
        if !record.genres.isEmpty { append(record.genres, field: .genres) }
        append(record.runtime, field: .runtime)
        append(record.posterURL, field: .posterURL)
        append(record.backdropURL, field: .backdropURL)
        append(record.logoURL, field: .logoURL)
        if record.title?.isEmpty == false { append(record.title, field: .title) }
        return values
    }

    private func writeMetadataValues(
        itemID: String,
        record: EnrichmentRecord,
        refreshedAt: Date,
        replaceExisting: Bool
    ) -> Bool {
        if replaceExisting {
            var delete: OpaquePointer?
            // Scoped to non-local sources ONLY: an external (re-)save must never
            // clobber a `localNFO`/`filename` candidate a separate, independently
            // versioned local worker wrote (see the local-vs-external write
            // isolation invariant — Step 3). Local writes have their own
            // `writeLocalMetadata`, which is scoped the mirror-opposite way.
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM metadata_values WHERE item_id=? AND source NOT IN ('localNFO','filename');",
                -1,
                &delete,
                nil
            ) == SQLITE_OK else { return false }
            bindText(delete, 1, itemID)
            let deleted = sqlite3_step(delete) == SQLITE_DONE
            sqlite3_finalize(delete)
            guard deleted else { return false }
        }

        let verb = replaceExisting ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        let sql = """
        \(verb) INTO metadata_values(
          item_id, field, source, value_json, source_url,
          source_revision, refreshed_at, expires_at
        ) VALUES(?,?,?,?,?,NULL,?,NULL);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        for value in persistedMetadataValues(for: record) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, itemID)
            bindText(stmt, 2, value.field.rawValue)
            bindText(stmt, 3, value.attribution.source.rawValue)
            bindText(stmt, 4, value.valueJSON)
            bindOptText(stmt, 5, value.attribution.sourceURL?.absoluteString)
            sqlite3_bind_double(stmt, 6, refreshedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func writeEnrichmentState(
        itemID: String,
        version: Int,
        attempts: Int,
        replaceExisting: Bool
    ) -> Bool {
        let sql: String
        if replaceExisting {
            sql = """
            INSERT INTO metadata_enrichment_state(
              item_id, local_version, external_version, local_attempts, external_attempts
            ) VALUES(?,NULL,?,0,?)
            ON CONFLICT(item_id) DO UPDATE SET
              external_version=excluded.external_version,
              external_attempts=excluded.external_attempts;
            """
        } else {
            sql = """
            INSERT INTO metadata_enrichment_state(
              item_id, local_version, external_version, local_attempts, external_attempts
            ) VALUES(?,NULL,?,0,?)
            ON CONFLICT(item_id) DO UPDATE SET
              external_version=COALESCE(
                metadata_enrichment_state.external_version,
                excluded.external_version
              ),
              external_attempts=CASE
                WHEN metadata_enrichment_state.external_version IS NULL
                THEN excluded.external_attempts
                ELSE metadata_enrichment_state.external_attempts
              END;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        sqlite3_bind_int64(stmt, 2, Int64(version))
        sqlite3_bind_int64(stmt, 3, Int64(attempts))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Backfill source-addressable rows from the flat projection without changing the
    /// projection or making any item newly eligible for enrichment.
    private func migrateLegacyEnrichmentMetadata() -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT item_id, provider_ids_json, overview, genres_json, runtime,
               poster_url, backdrop_url, logo_url, enriched_at,
               enrich_version, attempts, title
        FROM enrichment;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }

        var rows: [(String, EnrichmentRecord, Date, Int, Int)] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let itemID = columnText(stmt, 0) {
                var record = EnrichmentRecord()
                record.providerIDs = decodeJSON([String: String].self, columnText(stmt, 1)) ?? [:]
                record.overview = columnText(stmt, 2)
                record.genres = decodeJSON([String].self, columnText(stmt, 3)) ?? []
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    record.runtime = sqlite3_column_double(stmt, 4)
                }
                record.posterURL = columnText(stmt, 5).flatMap(URL.init(string:))
                record.backdropURL = columnText(stmt, 6).flatMap(URL.init(string:))
                record.logoURL = columnText(stmt, 7).flatMap(URL.init(string:))
                record.title = columnText(stmt, 11)
                record.inferLegacyProvenanceForMissingFields()
                rows.append((
                    itemID,
                    record,
                    Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                    Int(sqlite3_column_int64(stmt, 9)),
                    Int(sqlite3_column_int64(stmt, 10))
                ))
            }
            step = sqlite3_step(stmt)
        }
        let readSucceeded = step == SQLITE_DONE
        sqlite3_finalize(stmt)
        guard readSucceeded else { return false }

        for (itemID, record, refreshedAt, version, attempts) in rows {
            guard writeMetadataValues(
                itemID: itemID,
                record: record,
                refreshedAt: refreshedAt,
                replaceExisting: false
            ), writeEnrichmentState(
                itemID: itemID,
                version: version,
                attempts: attempts,
                replaceExisting: false
            ) else { return false }
        }
        return true
    }

    private func metadataMigrationComplete() -> Bool {
        var complete = false
        query("SELECT value FROM meta WHERE key='metadata_values_migrated_v1';") { stmt in
            complete = self.columnText(stmt, 0) == "1"
        }
        return complete
    }

    /// How many enrichment passes a miss is retried before it's settled as a genuine
    /// miss (bounded, not retried forever). Gives a transient rate-limit/timeout a
    /// few chances across scans to recover before the item is left blank.
    static let maxEnrichAttempts = 3
    /// Sentinel-free retry model: an unusable (empty) enrichment row is stored at
    /// the current `version` like any other, but this predicate (over a
    /// `LEFT JOIN enrichment e`) keeps it *pending* — retried up to
    /// `maxEnrichAttempts` — until it either resolves to something usable or is
    /// settled as a genuine miss. Matches a row with no ids, overview, or artwork.
    private static let unusableEnrichmentPredicate =
        "e.provider_ids_json IS NULL AND e.overview IS NULL AND e.poster_url IS NULL "
        + "AND e.backdrop_url IS NULL AND e.logo_url IS NULL"

    /// Logical items (movies + series) with no enrichment row at `version` yet,
    /// oldest-discovered first so a fresh library fills in a sensible order.
    func pendingEnrichment(
        version: Int,
        limit: Int,
        passStartedAt: Date? = nil
    ) -> [PendingEnrichment] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [PendingEnrichment] = []
        let cutoff = (passStartedAt ?? .distantFuture).timeIntervalSince1970

        // Movies: a movie asset is pending when it has no current-version enrichment
        // row, OR its row is an unusable miss still under the retry cap that wasn't
        // already attempted during this logical pass.
        query("""
        SELECT a.rel_path, a.title, a.year, a.first_seen_at FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'f:' || a.rel_path AND e.enrich_version = ?
        WHERE a.library='movies' AND a.kind='movie'
          AND a.first_seen_at <= ?
          AND (e.item_id IS NULL OR (
            \(Self.unusableEnrichmentPredicate) AND e.attempts < ?
            AND COALESCE(e.enriched_at, 0) < ?
          ))
        ORDER BY a.first_seen_at LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(version))
            sqlite3_bind_double($0, 2, cutoff)
            sqlite3_bind_int64($0, 3, Int64(Self.maxEnrichAttempts))
            sqlite3_bind_double($0, 4, cutoff)
            sqlite3_bind_int64($0, 5, Int64(limit))
        }) { stmt in
            let relPath = self.columnText(stmt, 0) ?? ""
            out.append(PendingEnrichment(
                itemID: ShareCatalogID.file(relPath),
                title: self.columnText(stmt, 1) ?? relPath,
                year: self.columnOptInt(stmt, 2),
                isMovie: true, isAnime: false,
                discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }

        // Series: one row per distinct series pending under the same rule.
        let remaining = max(0, limit - out.count)
        if remaining > 0 {
            query("""
            SELECT a.series_key, a.series_title, a.library, (
                SELECT b.year FROM assets b
                WHERE b.series_key = a.series_key AND b.kind='episode' AND b.year IS NOT NULL
                GROUP BY b.year ORDER BY COUNT(*) DESC, b.year ASC LIMIT 1
            ), MIN(a.first_seen_at) FROM assets a
            LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key AND e.enrich_version = ?
            WHERE a.kind='episode' AND a.series_key IS NOT NULL AND a.first_seen_at <= ?
              AND (e.item_id IS NULL OR (
                \(Self.unusableEnrichmentPredicate) AND e.attempts < ?
                AND COALESCE(e.enriched_at, 0) < ?
              ))
            GROUP BY a.series_key ORDER BY MIN(a.first_seen_at) LIMIT ?;
            """, bind: {
                sqlite3_bind_int64($0, 1, Int64(version))
                sqlite3_bind_double($0, 2, cutoff)
                sqlite3_bind_int64($0, 3, Int64(Self.maxEnrichAttempts))
                sqlite3_bind_double($0, 4, cutoff)
                sqlite3_bind_int64($0, 5, Int64(remaining))
            }) { stmt in
                guard let key = self.columnText(stmt, 0) else { return }
                let lib = self.columnText(stmt, 2) ?? "tv"
                out.append(PendingEnrichment(
                    itemID: ShareCatalogID.series(key),
                    title: self.columnText(stmt, 1) ?? key,
                    year: self.columnOptInt(stmt, 3),
                    isMovie: false, isAnime: lib == "anime",
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                ))
            }
        }
        return out
    }

    /// Total logical movies + series currently eligible for enrichment. Used only
    /// when a sliced pass begins so progress can retain one stable total across
    /// several short scheduler slices without loading the whole backlog into memory.
    func pendingEnrichmentCount(
        version: Int,
        discoveredBefore: Date? = nil
    ) -> Int {
        ensureOpen()
        guard db != nil else { return 0 }
        let cutoff = (discoveredBefore ?? .distantFuture).timeIntervalSince1970
        var movies = 0
        query("""
        SELECT COUNT(*) FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'f:' || a.rel_path AND e.enrich_version = ?
        WHERE a.library='movies' AND a.kind='movie'
          AND a.first_seen_at <= ?
          AND (e.item_id IS NULL OR (\(Self.unusableEnrichmentPredicate) AND e.attempts < ?));
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(version))
            sqlite3_bind_double($0, 2, cutoff)
            sqlite3_bind_int64($0, 3, Int64(Self.maxEnrichAttempts))
        }) { stmt in
            movies = Int(sqlite3_column_int64(stmt, 0))
        }

        var series = 0
        query("""
        SELECT COUNT(*) FROM (
          SELECT a.series_key FROM assets a
          LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key AND e.enrich_version = ?
          WHERE a.kind='episode' AND a.series_key IS NOT NULL AND a.first_seen_at <= ?
            AND (e.item_id IS NULL OR (\(Self.unusableEnrichmentPredicate) AND e.attempts < ?))
          GROUP BY a.series_key
        );
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(version))
            sqlite3_bind_double($0, 2, cutoff)
            sqlite3_bind_int64($0, 3, Int64(Self.maxEnrichAttempts))
        }) { stmt in
            series = Int(sqlite3_column_int64(stmt, 0))
        }
        return movies + series
    }

    /// The pending-enrichment request for a SINGLE catalog id (the item a user just
    /// opened), or `nil` when it's already enriched at `version`, isn't a logical
    /// movie/series, or is unknown. Lets the provider jump the viewed item to the
    /// front of the enrichment queue so its art/overview/ids persist promptly.
    func pendingEnrichment(forItemID id: String, version: Int) -> PendingEnrichment? {
        ensureOpen()
        guard db != nil else { return nil }

        // Logical movie → enrich its REPRESENTATIVE file (where movies() reads art),
        // so opening a movie fast-tracks the id the grid/detail actually display.
        if let mkey = ShareCatalogID.movieKey(forMovieID: id) {
            let groupKey = resolvedMovieGroupKey(mkey)
            var rep: String?
            query("""
            SELECT MIN(rel_path) FROM assets
            WHERE COALESCE(movie_group_key, movie_key)=?
              AND library='movies' AND kind='movie';
            """,
                  bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
            guard let rep else { return nil }
            return pendingEnrichment(forItemID: ShareCatalogID.file(rep), version: version)
        }

        // Series → the enrichment row is keyed by `series:<key>`.
        if ShareCatalogID.isSeries(id), let key = ShareCatalogID.seriesKey(forSeriesID: id) {
            let itemID = ShareCatalogID.series(key)
            if hasUsableEnrichment(itemID: itemID, version: version) { return nil }
            var out: PendingEnrichment?
            query("""
            SELECT series_title, library, (
                SELECT b.year FROM assets b
                WHERE b.series_key = ?1 AND b.kind='episode' AND b.year IS NOT NULL
                GROUP BY b.year ORDER BY COUNT(*) DESC, b.year ASC LIMIT 1
            ), MIN(first_seen_at) FROM assets WHERE series_key=?1 AND kind='episode' LIMIT 1;
            """,
                  bind: { self.bindText($0, 1, key) }) { stmt in
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
                let lib = self.columnText(stmt, 1) ?? "tv"
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? key,
                    year: self.columnOptInt(stmt, 2),
                    isMovie: false, isAnime: lib == "anime",
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                )
            }
            return out
        }

        // Movie file → the enrichment row is keyed by `f:<relPath>`. Episodes enrich
        // through their series (above), so a bare episode file id is skipped here.
        if let relPath = ShareCatalogID.relPath(forFileID: id) {
            let itemID = ShareCatalogID.file(relPath)
            if hasUsableEnrichment(itemID: itemID, version: version) { return nil }
            var out: PendingEnrichment?
            query("SELECT title, year, kind, first_seen_at FROM assets WHERE rel_path=?;",
                  bind: { self.bindText($0, 1, relPath) }) { stmt in
                guard (self.columnText(stmt, 2) ?? "movie") == "movie" else { return }
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? relPath,
                    year: self.columnOptInt(stmt, 1),
                    isMovie: true, isAnime: false,
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                )
            }
            return out
        }
        return nil
    }

    /// Whether `itemID` already has a **usable** enrichment row (any id / overview /
    /// artwork) at `version`. An unusable miss row does NOT count — so the fast-track
    /// path still re-attempts an item a user opens even after background retries
    /// settled it as a miss.
    private func hasUsableEnrichment(itemID: String, version: Int) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT 1 FROM enrichment WHERE item_id=? AND enrich_version=?
          AND (provider_ids_json IS NOT NULL OR overview IS NOT NULL OR poster_url IS NOT NULL
               OR backdrop_url IS NOT NULL OR logo_url IS NOT NULL) LIMIT 1;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        sqlite3_bind_int64(stmt, 2, Int64(version))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Persist one item's enrichment, **merging** onto any existing row so a later
    /// sparse/transient result can never erase richer ids/art already stored (a
    /// fast-track `enrichOne` racing the background drain, or a partial source
    /// outage). An **unusable** resolve (no ids/overview/art — usually a transient
    /// rate-limit or timeout) is NOT settled at `version`: it bumps an attempt
    /// counter and is stored with a sentinel version so it stays pending and the
    /// next pass retries it, up to `maxEnrichAttempts`, after which it's settled as
    /// a genuine miss (bounded, never retried forever). A usable result settles
    /// immediately. Returns `false` if the row could not be written.
    ///
    /// When strong anime ids (AniList/MAL) resolve for a series currently filed
    /// under TV, all its assets are reclassified to Anime — the Phase-2 "anime
    /// confirmed once ids resolve" correction.
    @discardableResult
    func saveEnrichment(itemID: String, _ record: EnrichmentRecord, version: Int, now: Date = Date()) -> Bool {
        ensureOpen()
        guard db != nil, normalizedMetadataReady else { return false }
        var record = record
        record.inferLegacyProvenanceForMissingFields()

        // Merge onto the existing row (if any) so a sparse write never clobbers
        // richer data — but ONLY within the same enrichment version. A version bump
        // means the resolver logic changed (often to CORRECT a wrong match), so its
        // result must fully REPLACE the old row rather than union with it; otherwise
        // stale artwork from a previous wrong match survives (e.g. a "TP" abbreviation
        // that once resolved TAP Portugal's logo would persist under the corrected
        // "The Punisher"). A usable fresh result at a new version is authoritative.
        let prior = enrichmentVersionAndAttempts(itemID: itemID)
        let isReResolveAfterBump = prior != nil && prior?.version != version && record.isUsable
        let merged = isReResolveAfterBump
            ? record
            : Self.merged(existing: enrichmentRow(itemID: itemID), new: record)
        // Attempt budget is PER VERSION: a future `ShareEnricher.version` bump (the
        // mechanism to re-enrich everything with improved sources) resets the budget
        // so a previously-exhausted miss gets the full retry count again, not one.
        // Within the same version the count accrues as before.
        let priorAttempts = (prior?.version == version) ? (prior?.attempts ?? 0) : 0
        let attempts = merged.isUsable ? 0 : priorAttempts + 1

        guard exec("BEGIN IMMEDIATE;") else { return false }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO enrichment
          (item_id, provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url, enriched_at, enrich_version, attempts, title)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(item_id) DO UPDATE SET
          provider_ids_json=excluded.provider_ids_json, overview=excluded.overview,
          genres_json=excluded.genres_json, runtime=excluded.runtime,
          poster_url=excluded.poster_url, backdrop_url=excluded.backdrop_url,
          logo_url=excluded.logo_url, enriched_at=excluded.enriched_at,
          enrich_version=excluded.enrich_version, attempts=excluded.attempts,
          title=excluded.title;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            _ = exec("ROLLBACK;")
            return false
        }
        bindText(stmt, 1, itemID)
        bindOptText(stmt, 2, encodeJSON(merged.providerIDs.isEmpty ? nil : merged.providerIDs))
        bindOptText(stmt, 3, merged.overview)
        bindOptText(stmt, 4, encodeJSON(merged.genres.isEmpty ? nil : merged.genres))
        if let rt = merged.runtime { sqlite3_bind_double(stmt, 5, rt) } else { sqlite3_bind_null(stmt, 5) }
        bindOptText(stmt, 6, merged.posterURL?.absoluteString)
        bindOptText(stmt, 7, merged.backdropURL?.absoluteString)
        bindOptText(stmt, 8, merged.logoURL?.absoluteString)
        sqlite3_bind_double(stmt, 9, now.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 10, Int64(version))
        sqlite3_bind_int64(stmt, 11, Int64(attempts))
        bindOptText(stmt, 12, merged.title)
        let projectionWritten = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        let normalizedWritten = projectionWritten && writeMetadataValues(
            itemID: itemID,
            record: merged,
            refreshedAt: now,
            replaceExisting: true
        )
        let stateWritten = normalizedWritten && writeEnrichmentState(
            itemID: itemID,
            version: version,
            attempts: attempts,
            replaceExisting: true
        )
        var derivedCatalogWritten = stateWritten
        if derivedCatalogWritten,
           ShareCatalogID.isSeries(itemID),
           let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            if merged.providerIDs.keys.contains(where: {
                ["anilist", "mal", "myanimelist"].contains($0.lowercased())
            }) {
                derivedCatalogWritten = reclassifySeriesToAnime(seriesKey: key)
            }
            if derivedCatalogWritten {
                derivedCatalogWritten = reconcileSeriesByStrongID(
                    key: key,
                    ids: merged.providerIDs,
                    resolvedTitle: merged.title
                )
            }
            if derivedCatalogWritten,
               enrichmentSaveFailurePoint == .afterDerivedCatalogMutations {
                derivedCatalogWritten = false
            }
        }
        let ok = derivedCatalogWritten && exec("COMMIT;")
        if ok {
            let repairItemIDs = pendingMergedSeriesLocalRepairs
            pendingMergedSeriesLocalRepairs.removeAll()
            for repairItemID in repairItemIDs {
                _ = materializeCachedLocalMetadata(itemID: repairItemID)
            }
            if !repairItemIDs.isEmpty {
                repairFilenameProviderIDs()
            }
        } else {
            _ = exec("ROLLBACK;")
            pendingMergedSeriesLocalRepairs.removeAll()
        }
        return ok
    }

    /// Merge a freshly-resolved record onto the existing one: prefer a new non-empty
    /// value for each field, keep the existing otherwise, and UNION provider ids
    /// (so a sparse pass can never drop ids another pass found).
    private static func merged(existing: EnrichmentRecord?, new: EnrichmentRecord) -> EnrichmentRecord {
        guard let existing else { return new }
        var out = existing
        if !new.providerIDs.isEmpty {
            var ids = existing.providerIDs
            for (k, v) in new.providerIDs where !v.isEmpty {
                ids[k] = v
                let field = MetadataField.providerID(k)
                if let source = new.provenance[field] { out.provenance[field] = source }
            }
            out.providerIDs = ids
        }
        if let o = new.overview, !o.isEmpty {
            out.overview = o
            out.provenance[.overview] = new.provenance[.overview]
        }
        if !new.genres.isEmpty {
            out.genres = new.genres
            out.provenance[.genres] = new.provenance[.genres]
        }
        if let r = new.runtime {
            out.runtime = r
            out.provenance[.runtime] = new.provenance[.runtime]
        }
        if let p = new.posterURL {
            out.posterURL = p
            out.provenance[.posterURL] = new.provenance[.posterURL]
        }
        if let b = new.backdropURL {
            out.backdropURL = b
            out.provenance[.backdropURL] = new.provenance[.backdropURL]
        }
        if let l = new.logoURL {
            out.logoURL = l
            out.provenance[.logoURL] = new.provenance[.logoURL]
        }
        if let t = new.title, !t.isEmpty {
            out.title = t
            out.provenance[.title] = new.provenance[.title]
        }
        return out
    }

    /// The stored `(enrich_version, attempts)` for `itemID`, or `nil` when no row
    /// exists. Lets `saveEnrichment` give each enrichment version its own retry
    /// budget (attempts accrue within a version, reset across a version bump).
    private func enrichmentVersionAndAttempts(itemID: String) -> (version: Int, attempts: Int)? {
        guard db != nil else { return nil }
        var out: (Int, Int)?
        query("SELECT enrich_version, attempts FROM enrichment WHERE item_id=?;", bind: { self.bindText($0, 1, itemID) }) { stmt in
            out = (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return out
    }

    private func reclassifySeriesToAnime(seriesKey: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE assets SET library='anime' WHERE series_key=? AND kind='episode' AND library<>'anime';", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, seriesKey)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Id-corroborated series reconciliation

    /// The strong (authoritative) external-id namespaces, in preference order, that
    /// are trustworthy enough to prove two series are the SAME show.
    private static let strongIDNamespaces = ["Tvdb", "Imdb", "Tmdb"]

    /// Fold `key` together with any OTHER already-enriched series that shares one of
    /// its strong external ids AND is near-identically titled (a typo/plural folder
    /// like "Peaky Blinder" vs "Peaky Blinders"). The shared id is the authoritative
    /// signal; the title check is a conservative guard so a provider mis-id can never
    /// collapse two genuinely different shows.
    private func reconcileSeriesByStrongID(
        key: String,
        ids: [String: String],
        resolvedTitle: String?
    ) -> Bool {
        guard db != nil else { return false }
        let myStrong = Self.strongIDNamespaces.compactMap { ns -> (String, String)? in
            guard let v = ids[ns], !v.isEmpty else { return nil }
            return (ns.lowercased(), v.lowercased())
        }
        guard !myStrong.isEmpty else { return true }
        let mySet = Set(myStrong.map { "\($0.0):\($0.1)" })

        // Candidate other series carrying at least one of the same strong ids.
        var candidates: [String] = []
        query("SELECT item_id, provider_ids_json FROM enrichment WHERE item_id LIKE 'series:%';") { stmt in
            guard let itemID = self.columnText(stmt, 0),
                  let k = ShareCatalogID.seriesKey(forSeriesID: itemID), k != key,
                  let json = self.columnText(stmt, 1),
                  let other = self.decodeJSON([String: String].self, json) else { return }
            let otherSet = Set(Self.strongIDNamespaces.compactMap { ns -> String? in
                guard let v = other[ns], !v.isEmpty else { return nil }
                return "\(ns.lowercased()):\(v.lowercased())"
            })
            if !mySet.isDisjoint(with: otherSet) { candidates.append(k) }
        }
        guard !candidates.isEmpty else { return true }

        let myTitle = seriesDisplayTitle(forKey: key)
        for other in candidates {
            let otherTitle = seriesDisplayTitle(forKey: other)
            guard Self.titlesNearlyIdentical(myTitle, otherTitle) else { continue }
            let (canonical, loser) = chooseCanonicalSeries(key, other, resolvedTitle: resolvedTitle)
            guard mergeSeries(loser: loser, into: canonical) else { return false }
        }
        return true
    }

    /// A representative display title for a series key (any episode's `series_title`).
    private func seriesDisplayTitle(forKey key: String) -> String {
        var title = key
        query("""
        SELECT series_title FROM assets
        WHERE series_key=? AND kind='episode' AND series_title IS NOT NULL AND series_title <> ''
        LIMIT 1;
        """, bind: { self.bindText($0, 1, key) }) { stmt in title = self.columnText(stmt, 0) ?? key }
        return title
    }

    /// Which of two same-id series is canonical: prefer the one whose title matches
    /// the resolved canonical name; else more episodes; else the lexicographically
    /// smaller key (stable). Returns `(canonical, loser)`.
    private func chooseCanonicalSeries(_ a: String, _ b: String, resolvedTitle: String?) -> (String, String) {
        if let resolved = resolvedTitle.map({ MediaItemIdentity.normalizedTitle($0) }), !resolved.isEmpty {
            let na = MediaItemIdentity.normalizedTitle(seriesDisplayTitle(forKey: a))
            let nb = MediaItemIdentity.normalizedTitle(seriesDisplayTitle(forKey: b))
            if na == resolved, nb != resolved { return (a, b) }
            if nb == resolved, na != resolved { return (b, a) }
        }
        let ea = seriesEpisodeCount(a), eb = seriesEpisodeCount(b)
        if ea != eb { return ea > eb ? (a, b) : (b, a) }
        return a <= b ? (a, b) : (b, a)
    }

    private func seriesEpisodeCount(_ key: String) -> Int {
        var n = 0
        query("SELECT COUNT(*) FROM assets WHERE series_key=? AND kind='episode';",
              bind: { self.bindText($0, 1, key) }) { stmt in n = Int(sqlite3_column_int64(stmt, 0)) }
        return n
    }

    /// Physically fold `loser` into `canonical`: re-key its assets, record the alias
    /// (so a re-scan re-applies it), retarget any aliases that pointed at `loser`,
    /// and drop the loser's now-redundant enrichment row.
    private func mergeSeries(loser: String, into canonical: String) -> Bool {
        guard loser != canonical else { return true }
        let loserID = ShareCatalogID.series(loser)
        let merged = runUpdate("UPDATE assets SET series_key=? WHERE series_key=?;") {
            self.bindText($0, 1, canonical)
            self.bindText($0, 2, loser)
        } && runUpdate("INSERT OR REPLACE INTO series_merge(alias_key, canonical_key) VALUES (?,?);") {
            self.bindText($0, 1, loser)
            self.bindText($0, 2, canonical)
        } && runUpdate("UPDATE series_merge SET canonical_key=? WHERE canonical_key=?;") {
            self.bindText($0, 1, canonical)
            self.bindText($0, 2, loser)
        } && runUpdate("""
            INSERT OR IGNORE INTO metadata_values(
              item_id, field, source, value_json, source_url,
              source_revision, refreshed_at, expires_at
            )
            SELECT ?, field, source, value_json, source_url,
                   source_revision, refreshed_at, expires_at
            FROM metadata_values
            WHERE item_id=? AND source IN ('localNFO','filename');
            """) {
            self.bindText($0, 1, ShareCatalogID.series(canonical))
            self.bindText($0, 2, loserID)
        } && runUpdate("""
            UPDATE local_metadata_files SET associated_item_id=?
            WHERE associated_item_id=?;
            """) {
            self.bindText($0, 1, ShareCatalogID.series(canonical))
            self.bindText($0, 2, loserID)
        } && runUpdate("DELETE FROM enrichment WHERE item_id=?;") {
            self.bindText($0, 1, loserID)
        } && runUpdate("DELETE FROM metadata_values WHERE item_id=?;") {
            self.bindText($0, 1, loserID)
        } && runUpdate("DELETE FROM metadata_enrichment_state WHERE item_id=?;") {
            self.bindText($0, 1, loserID)
        }
        if merged {
            pendingMergedSeriesLocalRepairs.insert(ShareCatalogID.series(canonical))
        }
        return merged
    }

    /// Run a parameterized write statement with a binder; finalizes cleanly.
    private func runUpdate(_ sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// All alias→canonical series-merge rows as a map, for in-memory resolution.
    private func seriesMergeMap() -> [String: String] {
        var map: [String: String] = [:]
        query("SELECT alias_key, canonical_key FROM series_merge;") { stmt in
            guard let a = self.columnText(stmt, 0), let c = self.columnText(stmt, 1) else { return }
            map[a] = c
        }
        return map
    }

    /// Resolve a series key through the alias map, following chains (bounded) so a
    /// transitively-merged key still lands on the final canonical.
    static func resolveAlias(_ key: String, in map: [String: String]) -> String {
        var current = key
        var seen = Set<String>()
        while let next = map[current], next != current, seen.insert(current).inserted {
            current = next
        }
        return current
    }

    /// Non-canonical "variant" words that must never be introduced by a display-title
    /// upgrade: a base show ("Sword Art Online") must not become a parody/recap
    /// ("Sword Art Online: Abridged") even if a bad match slips through.
    private static let variantWords: Set<String> = [
        "abridged", "recap", "parody", "condensed", "compilation", "fandub", "gagdub", "reaction",
    ]

    /// Whether `extended` (a normalized word-prefix-extension of `base`) adds a
    /// variant word not present in `base`.
    static func addsVariantWord(base: String, extended: String) -> Bool {
        let baseTokens = Set(base.split(separator: " ").map(String.init))
        let addedTokens = Set(extended.split(separator: " ").map(String.init)).subtracting(baseTokens)
        return !addedTokens.isDisjoint(with: variantWords)
    }

    /// Whether two series titles are near-identical enough to be a typo/plural of
    /// one show (Levenshtein ≤ 2 on the normalized forms, no DIGIT difference, and
    /// long enough that a couple of edits isn't most of the title). Combined with a
    /// shared strong id this is a very tight merge gate.
    static func titlesNearlyIdentical(_ a: String, _ b: String) -> Bool {
        let na = MediaItemIdentity.normalizedTitle(a)
        let nb = MediaItemIdentity.normalizedTitle(b)
        guard !na.isEmpty, !nb.isEmpty, na != nb else { return na == nb && !na.isEmpty }
        // A digit difference marks a deliberate distinction (1883 vs 1923, sequels).
        let digitsA = na.filter { $0.isNumber }, digitsB = nb.filter { $0.isNumber }
        guard digitsA == digitsB else { return false }
        let dist = levenshtein(na, nb)
        let shorter = min(na.count, nb.count)
        // Long enough that a couple of edits isn't a big fraction of the title — a
        // 5-letter word like "Fargo"/"Cargo" is one edit apart yet distinct.
        return dist <= 2 && shorter >= 8 && dist * 6 <= shorter
    }

    /// Classic Levenshtein edit distance (two-row DP).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }

    private func metadataValueMatches(
        field: MetadataField,
        valueJSON: String,
        record: EnrichmentRecord
    ) -> Bool {
        switch field {
        case .title:
            return decodeJSON(String.self, valueJSON) == record.title
        case .overview:
            return decodeJSON(String.self, valueJSON) == record.overview
        case .genres:
            return decodeJSON([String].self, valueJSON) == record.genres
        case .runtime:
            return decodeJSON(TimeInterval.self, valueJSON) == record.runtime
        case .posterURL:
            return decodeJSON(URL.self, valueJSON) == record.posterURL
        case .backdropURL:
            return decodeJSON(URL.self, valueJSON) == record.backdropURL
        case .logoURL:
            return decodeJSON(URL.self, valueJSON) == record.logoURL
        default:
            let prefix = "providerID."
            guard field.rawValue.hasPrefix(prefix) else { return false }
            let namespace = String(field.rawValue.dropFirst(prefix.count))
            guard let value = record.providerIDs.first(where: {
                $0.key.lowercased() == namespace
            })?.value else { return false }
            return decodeJSON(String.self, valueJSON) == value
        }
    }

    /// Load provenance for a page in one query. The flat row remains authoritative:
    /// malformed/stale normalized values are ignored and receive legacy attribution.
    private func hydratedEnrichmentRecords(
        _ records: [String: EnrichmentRecord]
    ) -> [String: EnrichmentRecord] {
        guard !records.isEmpty else { return [:] }
        guard normalizedMetadataReady else {
            return records.mapValues { record in
                var legacy = record
                legacy.inferLegacyProvenanceForMissingFields()
                return legacy
            }
        }
        let itemIDs = records.keys.sorted()
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        let sql = """
        SELECT item_id, field, source, value_json, source_url
        FROM metadata_values
        WHERE item_id IN (\(placeholders))
        ORDER BY item_id, field,
                 CASE WHEN source='legacyUnknown' THEN 1 ELSE 0 END,
                 COALESCE(refreshed_at, 0) DESC;
        """
        var stmt: OpaquePointer?
        var provenanceByItem: [String: MetadataProvenance] = [:]
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (offset, itemID) in itemIDs.enumerated() {
                bindText(stmt, Int32(offset + 1), itemID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let itemID = columnText(stmt, 0),
                      let record = records[itemID],
                      let fieldRaw = columnText(stmt, 1),
                      let sourceRaw = columnText(stmt, 2),
                      !sourceRaw.isEmpty,
                      let valueJSON = columnText(stmt, 3) else { continue }
                let field = MetadataField(rawValue: fieldRaw)
                var provenance = provenanceByItem[itemID] ?? MetadataProvenance()
                guard provenance[field] == nil,
                      metadataValueMatches(
                          field: field,
                          valueJSON: valueJSON,
                          record: record
                      ) else { continue }
                provenance[field] = MetadataAttribution(
                    source: MetadataSource(rawValue: sourceRaw),
                    sourceURL: columnText(stmt, 4).flatMap(URL.init(string:))
                )
                provenanceByItem[itemID] = provenance
            }
        }
        sqlite3_finalize(stmt)

        return records.reduce(into: [:]) { result, entry in
            let (itemID, record) = entry
            var hydrated = record
            hydrated.provenance = provenanceByItem[itemID] ?? MetadataProvenance()
            hydrated.inferLegacyProvenanceForMissingFields()
            result[itemID] = hydrated
        }
    }

    /// Persisted enrichment for a catalog id (movie file id or `series:<key>`).
    private func enrichmentRow(itemID: String) -> EnrichmentRecord? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url, title
        FROM enrichment WHERE item_id=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let record = enrichmentRecord(fromColumns: stmt, startingAt: 0) else { return nil }
        return hydratedEnrichmentRecords([itemID: record])[itemID]
    }

    /// Decode the enrichment columns (provider_ids_json, overview, genres_json,
    /// runtime, poster_url, backdrop_url, logo_url, title) starting at `startingAt`
    /// into a record. Shared by the standalone `enrichmentRow` lookup and the JOINed
    /// grid queries (movies/series), so a page fetch reads enrichment in ONE query
    /// instead of N+1 per-row lookups. Returns nil when the core columns are all NULL
    /// (no enrichment row matched the LEFT JOIN); `title` is a supplementary 8th
    /// column not counted in that emptiness check.
    private func enrichmentRecord(fromColumns stmt: OpaquePointer?, startingAt base: Int32) -> EnrichmentRecord? {
        let allNull = (0..<7).allSatisfy { sqlite3_column_type(stmt, base + $0) == SQLITE_NULL }
        if allNull { return nil }
        var rec = EnrichmentRecord()
        rec.providerIDs = decodeJSON([String: String].self, columnText(stmt, base + 0)) ?? [:]
        rec.overview = columnText(stmt, base + 1)
        rec.genres = decodeJSON([String].self, columnText(stmt, base + 2)) ?? []
        if sqlite3_column_type(stmt, base + 3) != SQLITE_NULL { rec.runtime = sqlite3_column_double(stmt, base + 3) }
        rec.posterURL = columnText(stmt, base + 4).flatMap(URL.init(string:))
        rec.backdropURL = columnText(stmt, base + 5).flatMap(URL.init(string:))
        rec.logoURL = columnText(stmt, base + 6).flatMap(URL.init(string:))
        rec.title = columnText(stmt, base + 7)
        return rec
    }

    /// Overlay persisted enrichment onto a freshly-built item. Movies/series use
    /// their own id; episodes/seasons inherit their series' art + ids (so an
    /// episode card shows the show art and carries the ids merge needs).
    private func withEnrichment(_ item: MediaItem) -> MediaItem {
        withEnrichment([item]).first ?? item
    }

    private func enrichmentKey(for item: MediaItem) -> String? {
        switch item.kind {
        case .series:
            return item.id
        case .movie:
            // A grouped movie (`movie:<key>`) stores its enrichment under the
            // group's REPRESENTATIVE file id (`f:<MIN(rel_path)>`) — where the
            // per-file enrichment pass already wrote art/ids — so resolve to that.
            // A legacy un-grouped `f:` movie id is its own enrichment key.
            return movieEnrichmentKey(forID: item.id)
        case .season, .episode:
            return item.seriesID
        default:
            return nil
        }
    }

    private func withEnrichment(_ items: [MediaItem]) -> [MediaItem] {
        let keyed = items.map { item in (item, enrichmentKey(for: item)) }
        let itemIDs = Array(Set(keyed.compactMap { $0.1 })).sorted()
        guard !itemIDs.isEmpty else { return withLocalOverlay(items) }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT item_id, provider_ids_json, overview, genres_json, runtime,
               poster_url, backdrop_url, logo_url, title
        FROM enrichment WHERE item_id IN (\(placeholders));
        """, -1, &stmt, nil) == SQLITE_OK else { return withLocalOverlay(items) }
        for (offset, itemID) in itemIDs.enumerated() {
            bindText(stmt, Int32(offset + 1), itemID)
        }
        var records: [String: EnrichmentRecord] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let itemID = columnText(stmt, 0),
                  let record = enrichmentRecord(fromColumns: stmt, startingAt: 1) else {
                continue
            }
            records[itemID] = record
        }
        sqlite3_finalize(stmt)
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(keyed.map { item, itemID in
            guard let itemID, let record = hydrated[itemID] else { return item }
            return applyEnrichment(item, record)
        })
    }

    /// Overlays persisted LOCAL (`localNFO`/`filename`) metadata onto items —
    /// taking priority over any external/legacy value `applyEnrichment` already
    /// applied above (NFO wins over a conflicting filename/folder tag, which in
    /// turn wins over external — see the Step 3 source-priority table). Local
    /// candidates are looked up by the SAME logical key local writes use (see
    /// `ShareLocalMetadataEnricher`): a movie's group-representative file id, a
    /// series' `series:<key>` id, or an EPISODE'S OWN `f:<relPath>` id — an
    /// episode's local NFO is never superseded by its show's `tvshow.nfo` (which
    /// only ever targets the series-level id). `sourceURL` is always nil for
    /// these sources — the local-provenance-privacy invariant.
    private func withLocalOverlay(_ items: [MediaItem]) -> [MediaItem] {
        guard normalizedMetadataReady, hasAnyLocalMetadata() else { return items }
        let keyed = items.map { item in (item, localMetadataKey(for: item)) }
        let itemIDs = Array(Set(keyed.compactMap { $0.1 })).sorted()
        guard !itemIDs.isEmpty else { return items }
        let rows = localMetadataRows(itemIDs: itemIDs)
        guard !rows.isEmpty else { return items }
        return keyed.map { item, key in
            guard let key, let fields = rows[key], !fields.isEmpty else { return item }
            return applyLocalMetadata(item, fields)
        }
    }

    /// Cheap, cached "does this catalog have ANY local metadata at all" check —
    /// see `hasAnyLocalMetadataCache`.
    private func hasAnyLocalMetadata() -> Bool {
        if let cached = hasAnyLocalMetadataCache { return cached }
        guard db != nil else { return false }
        var found = false
        query("SELECT 1 FROM metadata_values WHERE source IN ('localNFO','filename') LIMIT 1;") { _ in found = true }
        hasAnyLocalMetadataCache = found
        return found
    }

    private func localMetadataKey(for item: MediaItem) -> String? {
        switch item.kind {
        case .movie:
            return movieEnrichmentKey(forID: item.id)
        case .series, .episode:
            return item.id
        case .season:
            return item.seriesID
        default:
            return nil
        }
    }

    private struct LocalFieldRow {
        var source: MetadataSource
        var valueJSON: String
    }

    private func localMetadataRows(itemIDs: [String]) -> [String: [MetadataField: LocalFieldRow]] {
        guard !itemIDs.isEmpty, db != nil else { return [:] }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT item_id, field, source, value_json FROM metadata_values
        WHERE item_id IN (\(placeholders)) AND source IN ('localNFO','filename')
        ORDER BY item_id, field, CASE WHEN source='localNFO' THEN 0 ELSE 1 END;
        """, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (offset, itemID) in itemIDs.enumerated() { bindText(stmt, Int32(offset + 1), itemID) }
        var out: [String: [MetadataField: LocalFieldRow]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let itemID = columnText(stmt, 0),
                  let fieldRaw = columnText(stmt, 1),
                  let sourceRaw = columnText(stmt, 2),
                  let valueJSON = columnText(stmt, 3) else { continue }
            let field = MetadataField(rawValue: fieldRaw)
            var perItem = out[itemID] ?? [:]
            guard perItem[field] == nil else { continue } // First row per field wins (localNFO ordered first).
            perItem[field] = LocalFieldRow(source: MetadataSource(rawValue: sourceRaw), valueJSON: valueJSON)
            out[itemID] = perItem
        }
        return out
    }

    /// Recognized rating-source aliases mapped onto `RatingSource` for the
    /// `MediaItem.ratings` projection. Unrecognized sources stay losslessly in
    /// the persisted `metadata_values` payload but don't project here.
    private static func recognizedRatingSource(_ raw: String) -> RatingSource? {
        switch raw.lowercased() {
        case "imdb": return .imdb
        case "tmdb", "themoviedb": return .tmdb
        default: return nil
        }
    }

    private static func ratingScale(forMax max: Double) -> RatingScale {
        if abs(max - 100) < 0.001 { return .outOfHundred }
        if abs(max - 5) < 0.001 { return .outOfFive }
        return .outOfTen
    }

    private func applyLocalMetadata(_ item: MediaItem, _ fields: [MetadataField: LocalFieldRow]) -> MediaItem {
        var copy = item
        func attribution(for field: MetadataField) -> MetadataAttribution? {
            fields[field].map { MetadataAttribution(source: $0.source, sourceURL: nil) }
        }
        if let row = fields[.title], let value = decodeJSON(String.self, row.valueJSON), !value.isEmpty {
            copy.title = value
            copy.metadataProvenance[.title] = attribution(for: .title)
        }
        if let row = fields[.originalTitle], let value = decodeJSON(String.self, row.valueJSON), !value.isEmpty {
            copy.originalTitle = value
            copy.metadataProvenance[.originalTitle] = attribution(for: .originalTitle)
        }
        if let row = fields[.overview], let value = decodeJSON(String.self, row.valueJSON), !value.isEmpty {
            copy.overview = value
            copy.metadataProvenance[.overview] = attribution(for: .overview)
        }
        if let row = fields[.genres], let value = decodeJSON([String].self, row.valueJSON), !value.isEmpty {
            copy.genres = value
            copy.metadataProvenance[.genres] = attribution(for: .genres)
        }
        if let row = fields[.studios], let value = decodeJSON([String].self, row.valueJSON), !value.isEmpty {
            copy.studios = value
            copy.metadataProvenance[.studios] = attribution(for: .studios)
        }
        if let row = fields[.tags], let value = decodeJSON([String].self, row.valueJSON), !value.isEmpty {
            copy.tags = value
            copy.metadataProvenance[.tags] = attribution(for: .tags)
        }
        if let row = fields[.runtime], let value = decodeJSON(TimeInterval.self, row.valueJSON), value > 0 {
            copy.runtime = value
            copy.metadataProvenance[.runtime] = attribution(for: .runtime)
        }
        if let row = fields[.productionYear], let value = decodeJSON(Int.self, row.valueJSON) {
            copy.productionYear = value
            copy.metadataProvenance[.productionYear] = attribution(for: .productionYear)
        }
        if let row = fields[.seasonNumber], let value = decodeJSON(Int.self, row.valueJSON) {
            copy.seasonNumber = value
            copy.metadataProvenance[.seasonNumber] = attribution(for: .seasonNumber)
        }
        if let row = fields[.episodeNumber], let value = decodeJSON(Int.self, row.valueJSON) {
            copy.episodeNumber = value
            copy.metadataProvenance[.episodeNumber] = attribution(for: .episodeNumber)
        }
        if let row = fields[.ratings], let value = decodeJSON([ParsedNFORating].self, row.valueJSON), !value.isEmpty {
            let recognized: [ExternalRating] = value.compactMap { rating in
                guard let source = Self.recognizedRatingSource(rating.source), rating.max > 0 else { return nil }
                return ExternalRating(source: source, value: rating.value, scale: Self.ratingScale(forMax: rating.max))
            }
            if !recognized.isEmpty {
                copy.ratings = copy.ratings.mergedWithAuthoritative(recognized)
                copy.metadataProvenance[.ratings] = attribution(for: .ratings)
            }
        }
        // Provider ids: local wins per-namespace over whatever's already present.
        for (field, row) in fields where field.rawValue.hasPrefix("providerID.") {
            guard let value = decodeJSON(String.self, row.valueJSON), !value.isEmpty else { continue }
            let namespace = String(field.rawValue.dropFirst("providerID.".count))
            copy.providerIDs = copy.providerIDs.filter {
                ShareExplicitIDPolicy.canonicalNamespace($0.key) != namespace
            }
            copy.providerIDs[ShareExplicitIDPolicy.projectedKey(namespace: namespace)] = value
            copy.metadataProvenance[field] = attribution(for: field)
        }
        return copy
    }


    /// The enrichment row id for a movie item: the group's representative file id
    /// for a logical `movie:<key>`, else the id unchanged (a legacy `f:` movie).
    private func movieEnrichmentKey(forID id: String) -> String {
        guard let mkey = ShareCatalogID.movieKey(forMovieID: id) else { return id }
        let groupKey = resolvedMovieGroupKey(mkey)
        var rep: String?
        query("""
        SELECT 'f:' || MIN(rel_path) FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=?
          AND library='movies' AND kind='movie';
        """,
              bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
        return rep ?? id
    }

    /// Merge an already-fetched enrichment record onto an item. Extracted from
    /// `withEnrichment` so the JOINed grid queries can reuse the exact same merge.
    private func applyEnrichment(_ item: MediaItem, _ rec: EnrichmentRecord) -> MediaItem {
        var copy = item
        if copy.metadataProvenance[.title] == nil {
            copy.metadataProvenance[.title] = MetadataAttribution(source: .filename)
        }
        func adopt(_ field: MetadataField) {
            if let attribution = rec.provenance[field] {
                copy.metadataProvenance[field] = attribution
            }
        }
        // Merge ids (don't clobber any already present).
        if !rec.providerIDs.isEmpty {
            var ids = copy.providerIDs
            for (k, v) in rec.providerIDs where ids[k] == nil {
                ids[k] = v
                adopt(.providerID(k))
            }
            copy.providerIDs = ids
        }
        if (copy.overview?.isEmpty ?? true), item.kind != .episode, let overview = rec.overview {
            copy.overview = overview
            adopt(.overview)
        }
        if copy.genres.isEmpty, !rec.genres.isEmpty {
            copy.genres = rec.genres
            adopt(.genres)
        }
        if copy.runtime == nil, let rt = rec.runtime, item.kind == .movie {
            copy.runtime = rt
            adopt(.runtime)
        }
        if copy.posterURL == nil, let poster = rec.posterURL {
            copy.posterURL = poster
            adopt(.posterURL)
        }
        if copy.backdropURL == nil, let backdrop = rec.backdropURL {
            copy.backdropURL = backdrop
            adopt(.backdropURL)
        }
        if copy.heroBackdropURL == nil, let backdrop = rec.backdropURL {
            copy.heroBackdropURL = backdrop
            adopt(.backdropURL)
        }
        if copy.logoURL == nil, let logo = rec.logoURL {
            copy.logoURL = logo
            adopt(.logoURL)
        }
        // Display-title upgrade (series/movies only, never episodes): overlay the
        // resolved canonical name when it's IDENTICAL, MORE SPECIFIC (current is a
        // word-prefix of resolved), or a NEAR-IDENTICAL typo/plural of the current
        // ("Peaky Blinder" → "Peaky Blinders") — so a generic or misspelled folder
        // shows the real name, but a spinoff that wrongly matched its parent is never
        // renamed DOWN. A more-specific upgrade must NOT add a non-canonical variant
        // word (abridged/recap/…): "Sword Art Online" must never become "Sword Art
        // Online: Abridged" even if a bad match slips through. Applied at READ time
        // so it's durable across re-scans.
        if item.kind == .series || item.kind == .movie,
           let resolved = rec.title, !resolved.isEmpty, resolved != copy.title {
            let a = MediaItemIdentity.normalizedTitle(copy.title)
            let b = MediaItemIdentity.normalizedTitle(resolved)
            let moreSpecific = b.hasPrefix(a + " ") && !Self.addsVariantWord(base: a, extended: b)
            if b == a || moreSpecific || Self.titlesNearlyIdentical(copy.title, resolved) {
                copy.title = resolved
                adopt(.title)
            }
        }
        // Episodes get the series art as a fallback, not as their own poster.
        if item.kind == .episode {
            if copy.seriesPosterURL == nil, let poster = rec.posterURL {
                copy.seriesPosterURL = poster
                adopt(.posterURL)
            }
            copy.posterURL = item.posterURL // keep episode's own (none yet) — series art via fallback field
        }
        return copy
    }

    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Read path (build MediaItems)

    /// Whether the catalog has any indexed content yet (false on a fresh share
    /// before the first scan populates it).
    func isEmpty() -> Bool { count(where: nil) == 0 }

    /// Per-library counts so `libraries()` can hide an indexed library that has no
    /// content yet (movies = files; tv/anime = distinct series).
    func libraryCounts() -> (movies: Int, tvSeries: Int, animeSeries: Int) {
        ensureOpen()
        let movies = count(where: "library='movies' AND kind='movie'")
        let tv = distinctSeriesCount(library: .tv)
        let anime = distinctSeriesCount(library: .anime)
        return (movies, tv, anime)
    }

    /// Recently added: movies + one entry per series (stamped with the series'
    /// newest episode discovery time), newest first. Non-network — Home hot path safe.
    func latest(limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [(added: Double, item: MediaItem)] = []

        // Movies — grouped by movie_key so a multi-file film is one Recently Added
        // card, dated by the FIRST version discovered (when the movie appeared).
        query("""
        SELECT
          CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
               THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year), MIN(first_seen_at) AS added
        FROM assets WHERE library='movies' AND kind='movie'
        GROUP BY COALESCE(movie_group_key, movie_key, rel_path)
        ORDER BY added DESC LIMIT ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            let item = MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            )
            out.append((self.columnDouble(stmt, 3), item))
        }

        // Series (tv + anime), represented by the series card, dated by newest episode.
        query("""
        SELECT series_key, series_title, library, MAX(first_seen_at) AS added, MAX(year)
        FROM assets WHERE kind='episode' AND series_key IS NOT NULL
        GROUP BY series_key, library ORDER BY added DESC LIMIT ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let lib = CatalogLibrary(rawValue: self.columnText(stmt, 2) ?? "tv") ?? .tv
            out.append((self.columnDouble(stmt, 3), self.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: lib, year: self.columnOptInt(stmt, 4))))
        }

        return withEnrichment(
            out.sorted { $0.added > $1.added }.prefix(limit).map(\.item)
        )
    }

    /// Free-text search across movie/episode titles and series titles. `LIKE` is
    /// fine at share scale (a few thousand rows) and stays index-light; FTS is a
    /// later refinement. Returns movie + series items.
    func search(query q: String, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        let needle = "%\(q.lowercased())%"
        var out: [MediaItem] = []

        query("""
        SELECT
          CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
               THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year)
        FROM assets
        WHERE library='movies' AND kind='movie' AND LOWER(title) LIKE ?
        GROUP BY COALESCE(movie_group_key, movie_key, rel_path) LIMIT ?;
        """, bind: {
            self.bindText($0, 1, needle); sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            out.append(MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            ))
        }

        query("""
        SELECT series_key, series_title, library, MAX(year) FROM assets
        WHERE kind='episode' AND series_key IS NOT NULL AND LOWER(series_title) LIKE ?
        GROUP BY series_key, library LIMIT ?;
        """, bind: {
            self.bindText($0, 1, needle); sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let lib = CatalogLibrary(rawValue: self.columnText(stmt, 2) ?? "tv") ?? .tv
            out.append(self.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: lib, year: self.columnOptInt(stmt, 3)))
        }

        return withEnrichment(Array(out.prefix(limit)))
    }

    /// Movie items for the Movies library grid (paged). Movies are **grouped** by
    /// `movie_key` so several files of one film collapse to a single logical card
    /// (`movie:<key>`); a row with no key (pre-reparse) stands alone under its own
    /// `f:<rel_path>` id via `COALESCE`. Enrichment is read from the group's
    /// representative file id (`f:<MIN(rel_path)>`), which already carries art —
    /// so grouping never blanks a card.
    func movies(offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil else { return [] }
        var rows: [(item: MediaItem, enrichmentID: String, record: EnrichmentRecord?)] = []
        query("""
        SELECT g.logical_id, g.title, g.year, g.rep_id,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url, e.title
        FROM (
          SELECT
            CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
                 THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
                 ELSE 'f:' || MIN(rel_path) END AS logical_id,
            'f:' || MIN(rel_path) AS rep_id,
            MIN(title) AS title, MAX(year) AS year, MIN(sort_title) AS gsort
          FROM assets WHERE library='movies' AND kind='movie'
          GROUP BY COALESCE(movie_group_key, movie_key, rel_path)
        ) g
        LEFT JOIN enrichment e ON e.item_id = g.rep_id
        -- A winning NFO `sortTitle` candidate (see the Step 3 field table) sorts
        -- the grid AHEAD of the scan-owned `assets.sort_title` — computed here so
        -- pagination (LIMIT/OFFSET) already reflects it; `assets.sort_title` itself
        -- is never mutated (it stays the scanner's own fallback).
        LEFT JOIN metadata_values sv
          ON sv.item_id = g.rep_id AND sv.field = 'sortTitle' AND sv.source = 'localNFO'
        ORDER BY COALESCE(substr(sv.value_json, 2, length(sv.value_json) - 2), g.gsort), g.title, g.logical_id
        LIMIT ? OFFSET ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)); sqlite3_bind_int64($0, 2, Int64(offset)) }) { stmt in
            let item = MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            )
            rows.append((
                item,
                self.columnText(stmt, 3) ?? item.id,
                self.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(rows.map { row in
            hydrated[row.enrichmentID].map { applyEnrichment(row.item, $0) } ?? row.item
        })
    }

    /// Distinct series items for a TV/Anime library, alphabetical.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil, library != .movies else { return [] }
        var rows: [(item: MediaItem, enrichmentID: String, record: EnrichmentRecord?)] = []
        // LEFT JOIN enrichment (keyed "series:<series_key>") into the grouped query so
        // a page is one query, not 1 + N per-row enrichment lookups. The GROUP BY is
        // over series_key, which the JOIN is 1:1 with.
        query("""
        SELECT a.series_key, MIN(a.series_title), MAX(a.year), MIN(a.sort_title) AS s,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url, e.title
        FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key
        LEFT JOIN metadata_values sv
          ON sv.item_id = 'series:' || a.series_key AND sv.field = 'sortTitle' AND sv.source = 'localNFO'
        WHERE a.library=? AND a.kind='episode' AND a.series_key IS NOT NULL
        GROUP BY a.series_key
        ORDER BY COALESCE(substr(MIN(sv.value_json), 2, length(MIN(sv.value_json)) - 2), s), a.series_key
        LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit)); sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let item = self.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: library, year: self.columnOptInt(stmt, 2))
            rows.append((
                item,
                ShareCatalogID.series(key),
                self.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(rows.map { row in
            hydrated[row.enrichmentID].map { applyEnrichment(row.item, $0) } ?? row.item
        })
    }

    /// Exact number of movies in the Movies library, for the grid's `totalCount`
    /// so it can size its sparse backing store once and random-access any page
    /// (jump-to-bottom). Counts DISTINCT logical movies (grouped by `movie_key`,
    /// falling back to `rel_path` for un-keyed rows) to match `movies()`.
    func movieCount() -> Int {
        ensureOpen()
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT COALESCE(movie_group_key, movie_key, rel_path)) FROM assets WHERE library='movies' AND kind='movie';", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Exact number of distinct series in a TV/Anime library, for the grid's
    /// `totalCount`. Zero for the movies library (which has no series).
    func seriesCount(in library: CatalogLibrary) -> Int {
        library == .movies ? 0 : distinctSeriesCount(library: library)
    }

    /// Season container items for a series (distinct season numbers; a `NULL`
    /// season is treated as season 1).
    func seasons(seriesKey: String) -> [MediaItem] {
        ensureOpen()
        guard db != nil else { return [] }
        var seriesTitle = seriesKey
        var library: CatalogLibrary = .tv
        var seasons: [Int] = []
        query("""
        SELECT COALESCE(season,1) AS s,
               MIN(series_title) AS canonical_title,
               MAX(CASE WHEN library='anime' THEN 1 ELSE 0 END) AS has_anime
        FROM assets
        WHERE series_key=? AND kind='episode'
        GROUP BY COALESCE(season,1)
        ORDER BY s;
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            seasons.append(Int(sqlite3_column_int64(stmt, 0)))
            if let t = self.columnText(stmt, 1) { seriesTitle = t }
            if sqlite3_column_int64(stmt, 2) != 0 { library = .anime }
        }
        return withEnrichment(seasons.map { n in
            MediaItem(
                id: ShareCatalogID.season(seriesKey, n),
                title: "Season \(n)",
                kind: .season,
                parentTitle: seriesTitle,
                seasonNumber: n,
                seriesID: ShareCatalogID.series(seriesKey),
                libraryID: ShareCatalogID.library(library)
            )
        })
    }

    /// Up to `limit` on-disk episode fingerprints (season, episode, title) for a
    /// series — the earliest seasons/episodes with a real title — used to
    /// disambiguate a same-name metadata collision by content. Skips episodes with
    /// no parsed title (nothing to match on).
    /// On-disk episode-title fingerprints for content-based series disambiguation.
    /// EXCLUDES the synthetic `S<n>·E<nn>` placeholder titles that bare-numbered
    /// files get (they carry no real title) — otherwise a show whose early seasons
    /// are bare-numbered (Outlander) would send only useless placeholders and match
    /// nothing, falling through to a wrong same-named show. Real titles from any
    /// season are used instead.
    func episodeTitleHints(seriesKey: String, limit: Int = 12) -> [(season: Int, episode: Int, title: String)] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [(season: Int, episode: Int, title: String)] = []
        query("""
        SELECT COALESCE(season,1) AS s, episode, title FROM assets
        WHERE series_key=? AND kind='episode' AND episode IS NOT NULL
          AND title IS NOT NULL AND title <> ''
          AND title NOT LIKE 'S%·E%'
        ORDER BY s, episode
        LIMIT ?;
        """, bind: {
            self.bindText($0, 1, seriesKey)
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            let s = Int(sqlite3_column_int64(stmt, 0))
            let e = Int(sqlite3_column_int64(stmt, 1))
            guard let t = self.columnText(stmt, 2) else { return }
            out.append((season: s, episode: e, title: t))
        }
        return out
    }

    /// Distinct FILENAME-derived series titles for a series that differ from its
    /// stored (folder-derived) title — extra TVDB search candidates for a show
    /// whose folder is generic. A generic "Avatar (2024)" folder stores title
    /// "Avatar", but the files say "Avatar The Last Airbender"; offering that as a
    /// search alternate lets enrichment find the right series. Returns candidates
    /// longest-first (most specific), capped, excluding the stored title.
    func seriesSearchTitleAlternates(seriesKey: String, storedTitle: String, sampleLimit: Int = 24) -> [String] {
        ensureOpen()
        guard db != nil, sampleLimit > 0 else { return [] }
        var relPaths: [String] = []
        query("""
        SELECT rel_path FROM assets
        WHERE series_key=? AND kind='episode' AND rel_path IS NOT NULL AND rel_path <> ''
        ORDER BY COALESCE(season,1), COALESCE(episode, 999999)
        LIMIT ?;
        """, bind: {
            self.bindText($0, 1, seriesKey)
            sqlite3_bind_int64($0, 2, Int64(sampleLimit))
        }) { stmt in
            if let p = self.columnText(stmt, 0) { relPaths.append(p) }
        }
        let storedNorm = storedTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        // Only a RICHER filename title is a useful alternate: it must have more words
        // than the stored folder title ("Avatar" → "Avatar The Last Airbender"). A
        // shorter filename abbreviation ("TP" for a "The Punisher" folder) must NOT
        // be searched — it fuzzy-matches unrelated shows ("The Syd + TP Show").
        let storedWordCount = storedNorm.split(separator: " ").count
        var seen = Set<String>()
        var alternates: [String] = []
        for path in relPaths {
            guard let title = ShareMediaParser.filenameSeriesTitle(relPath: path) else { continue }
            let norm = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
            guard !norm.isEmpty, norm != storedNorm, seen.insert(norm).inserted,
                  norm.split(separator: " ").count > storedWordCount else { continue }
            alternates.append(title)
        }
        // Most specific first: a longer filename title ("Avatar The Last
        // Airbender") is a stronger search than a short one.
        return alternates.sorted { $0.count > $1.count }
    }

    /// The explicit TheTVDB id a series' folder/filenames declared via a
    /// `[tvdb-####]` tag, or nil. Read from a sample rel_path — the enricher uses it
    /// to resolve metadata authoritatively by id instead of an ambiguous title search.
    func seriesEmbeddedTVDBID(seriesKey: String) -> String? {
        ensureOpen()
        guard db != nil else { return nil }
        var relPath: String?
        query("""
        SELECT rel_path FROM assets
        WHERE series_key=? AND kind='episode' AND rel_path IS NOT NULL AND rel_path <> ''
        LIMIT 1;
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            relPath = self.columnText(stmt, 0)
        }
        guard let relPath, let tag = ShareMediaParser.embeddedProviderTag(relPath: relPath),
              tag.hasPrefix("tvdb-") else { return nil }
        let id = String(tag.dropFirst("tvdb-".count))
        return id.isEmpty ? nil : id
    }
    func episodes(seriesKey: String, season: Int) -> [MediaItem] {        ensureOpen()
        guard db != nil else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT rel_path, title, series_title, season, episode, library, year FROM assets
        WHERE series_key=? AND kind='episode' AND COALESCE(season,1)=?
        ORDER BY COALESCE(episode, 999999), sort_title, rel_path;
        """, bind: { self.bindText($0, 1, seriesKey); sqlite3_bind_int64($0, 2, Int64(season)) }) { stmt in
            out.append(self.episodeItem(from: stmt, seriesKey: seriesKey))
        }
        return withEnrichment(out)
    }

    /// Resolve any catalog id to a rich `MediaItem`, or `nil` if unknown here
    /// (caller falls back to the raw browser for `share:root` / `d:` ids).
    func item(id: String) -> MediaItem? {
        ensureOpen()
        guard db != nil else { return nil }
        if let mkey = ShareCatalogID.movieKey(forMovieID: id) {
            return movieItem(key: mkey)
        }
        if let key = ShareCatalogID.seriesKey(forSeriesID: id) {
            var title = key
            var library: CatalogLibrary = .tv
            var year: Int?
            var found = false
            query("""
            SELECT series_title, library, (
                SELECT b.year FROM assets b
                WHERE b.series_key = ?1 AND b.kind='episode' AND b.year IS NOT NULL
                GROUP BY b.year ORDER BY COUNT(*) DESC, b.year ASC LIMIT 1
            ) FROM assets WHERE series_key=?1 AND kind='episode' LIMIT 1;
            """,
                  bind: { self.bindText($0, 1, key) }) { stmt in
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { title = self.columnText(stmt, 0) ?? key; found = true }
                library = CatalogLibrary(rawValue: self.columnText(stmt, 1) ?? "tv") ?? .tv
                year = self.columnOptInt(stmt, 2)
            }
            return found ? withEnrichment(seriesItem(key: key, title: title, library: library, year: year)) : nil
        }
        if let (key, season) = ShareCatalogID.seasonComponents(forSeasonID: id) {
            return seasons(seriesKey: key).first { $0.seasonNumber == season }
        }
        if let relPath = ShareCatalogID.relPath(forFileID: id) {
            var result: MediaItem?
            query("""
            SELECT rel_path, title, kind, library, year, series_title, series_key, season, episode,
                   basename, size
            FROM assets WHERE rel_path=?;
            """, bind: { self.bindText($0, 1, relPath) }) { stmt in
                let kind = self.columnText(stmt, 2) ?? "movie"
                if kind == "episode" {
                    result = self.episodeItem(from: stmt, seriesKey: self.columnText(stmt, 6) ?? "")
                } else {
                    result = MediaItem(
                        id: ShareCatalogID.file(relPath),
                        title: self.columnText(stmt, 1) ?? relPath,
                        kind: .movie,
                        productionYear: self.columnOptInt(stmt, 4),
                        libraryID: ShareCatalogID.moviesLibrary,
                        versions: [Self.movieVersion(
                            relPath: relPath,
                            basename: self.columnText(stmt, 9) ?? relPath,
                            size: sqlite3_column_int64(stmt, 10)
                        )]
                    )
                }
            }
            if let result { return withEnrichment(result) }
            if let group = movieAliasGroup(for: id) { return movieItem(key: group) }
            return nil
        }
        return nil
    }

    // MARK: - Item builders

    /// Build the logical movie (`movie:<key>`) for a detail page: its files become
    /// selectable ``MediaVersion``s (best-quality first, one flagged default), so
    /// the version picker lets the user choose which file plays — the share's local
    /// equivalent of the multi-file movie a Plex/Jellyfin server returns as one
    /// item. A single-file movie exposes no versions (no picker). Enrichment is
    /// applied via the group's representative file (see `movieEnrichmentKey`).
    private func movieItem(key: String) -> MediaItem? {
        let groupKey = resolvedMovieGroupKey(key)
        var files: [(relPath: String, basename: String, size: Int64)] = []
        var title: String?
        var year: Int?
        query("""
        SELECT rel_path, basename, size, title, year FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=?
          AND library='movies' AND kind='movie' ORDER BY rel_path;
        """, bind: { self.bindText($0, 1, groupKey) }) { stmt in
            let rel = self.columnText(stmt, 0) ?? ""
            files.append((rel, self.columnText(stmt, 1) ?? rel, sqlite3_column_int64(stmt, 2)))
            if title == nil { title = self.columnText(stmt, 3) }
            if let y = self.columnOptInt(stmt, 4) { year = max(year ?? y, y) }
        }
        guard !files.isEmpty else { return nil }
        var versions = files.map { Self.movieVersion(relPath: $0.relPath, basename: $0.basename, size: $0.size) }
            .sortedForPicker()
        if !versions.isEmpty { versions[0].isDefault = true }
        let item = MediaItem(
            id: ShareCatalogID.movie(groupKey),
            title: title ?? groupKey,
            kind: .movie,
            productionYear: year,
            libraryID: ShareCatalogID.moviesLibrary,
            // Retain even one named SMB version. The picker still requires >1,
            // while same-account/cross-server merging can preserve its filename
            // and quality instead of synthesizing an anonymous "Version".
            versions: versions
        )
        return withEnrichment(item)
    }

    /// The best default file to play for a logical movie when the caller named no
    /// specific version (play-from-card, before the detail's version picker set
    /// one): the highest parsed resolution, then the largest file.
    func defaultMovieRelPath(forKey key: String) -> String? {
        ensureOpen()
        guard db != nil else { return nil }
        let groupKey = resolvedMovieGroupKey(key)
        var best: (rel: String, height: Int, size: Int64)?
        query("""
        SELECT rel_path, basename, size FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=?
          AND library='movies' AND kind='movie';
        """,
              bind: { self.bindText($0, 1, groupKey) }) { stmt in
            let rel = self.columnText(stmt, 0) ?? ""
            let h = Self.resolutionHeight(fromName: self.columnText(stmt, 1) ?? "") ?? 0
            let sz = sqlite3_column_int64(stmt, 2)
            if best == nil || h > best!.height || (h == best!.height && sz > best!.size) {
                best = (rel, h, sz)
            }
        }
        return best?.rel
    }

    /// Canonical watch-state id for a leaf id: a movie file (`f:<rel>`) folds into
    /// its logical `movie:<key>` so resume/played is unified across versions; an
    /// episode file or an un-keyed movie keeps its own id.
    func canonicalItemID(_ id: String) -> String {
        ensureOpen()
        guard db != nil else { return id }
        if let key = ShareCatalogID.movieKey(forMovieID: id) {
            return ShareCatalogID.movie(resolvedMovieGroupKey(key))
        }
        guard let rel = ShareCatalogID.relPath(forFileID: id) else { return id }
        var key: String?
        query("SELECT COALESCE(movie_group_key, movie_key) FROM assets WHERE rel_path=? AND kind='movie';",
              bind: { self.bindText($0, 1, rel) }) { stmt in key = self.columnText(stmt, 0) }
        if let key { return ShareCatalogID.movie(key) }
        if let group = movieAliasGroup(for: id) { return ShareCatalogID.movie(group) }
        return id
    }

    /// Stored watch-state ids relevant to the requested current items, mapped to
    /// their canonical ids. Normal grid/detail/search stamping uses this bounded
    /// alias set instead of canonicalizing the entire watch history.
    func watchStateAliases(for itemIDs: [String]) -> [String: String] {
        ensureOpen()
        guard db != nil, !itemIDs.isEmpty else { return [:] }

        var aliases: [String: String] = [:]
        var canonicalByGroup: [String: String] = [:]
        for id in itemIDs {
            let canonical = canonicalItemID(id)
            aliases[id] = canonical
            aliases[canonical] = canonical
            if let group = ShareCatalogID.movieKey(forMovieID: canonical) {
                canonicalByGroup[group] = canonical
            }
        }

        let groups = Array(canonicalByGroup.keys)
        guard !groups.isEmpty else { return aliases }
        let placeholders = Array(repeating: "?", count: groups.count).joined(separator: ",")
        query("SELECT alias_id, group_key FROM movie_alias WHERE group_key IN (\(placeholders));",
              bind: { stmt in
                  for (offset, group) in groups.enumerated() {
                      self.bindText(stmt, Int32(offset + 1), group)
                  }
              }) { stmt in
            guard let alias = self.columnText(stmt, 0),
                  let group = self.columnText(stmt, 1),
                  let canonical = canonicalByGroup[group] else { return }
            let storedID = alias.hasPrefix("f:") ? alias : ShareCatalogID.movie(alias)
            aliases[storedID] = canonical
        }
        return aliases
    }

    /// Whether a legacy/raw `f:` id still has a live catalog row. Playback uses
    /// this to preserve exact-file selection for existing files while routing a
    /// deleted legacy file alias to the surviving logical movie.
    func containsFileAsset(id: String) -> Bool {
        ensureOpen()
        guard db != nil, let relPath = ShareCatalogID.relPath(forFileID: id) else { return false }
        var found = false
        query("SELECT 1 FROM assets WHERE rel_path=? LIMIT 1;",
              bind: { self.bindText($0, 1, relPath) }) { _ in found = true }
        return found
    }

    /// Resolve a pre-grouping `movie:<movie_key>` id to its persisted logical
    /// group. Keeps v3 Continue Watching records, deep links, and queued watch
    /// writes working after v4 combines adjacent-year variants.
    private func resolvedMovieGroupKey(_ key: String) -> String {
        ensureOpen()
        guard db != nil else { return key }
        var resolved: String?
        query("""
        SELECT COALESCE(movie_group_key, movie_key) FROM assets
        WHERE library='movies' AND kind='movie' AND movie_key=? LIMIT 1;
        """, bind: { self.bindText($0, 1, key) }) { stmt in
            resolved = self.columnText(stmt, 0)
        }
        if let resolved { return resolved }
        query("""
        SELECT movie_group_key FROM assets
        WHERE library='movies' AND kind='movie' AND movie_group_key=? LIMIT 1;
        """, bind: { self.bindText($0, 1, key) }) { stmt in
            resolved = self.columnText(stmt, 0)
        }
        if let resolved { return resolved }
        return movieAliasGroup(for: key) ?? key
    }

    private func movieAliasGroup(for aliasID: String) -> String? {
        var group: String?
        query("SELECT group_key FROM movie_alias WHERE alias_id=? LIMIT 1;",
              bind: { self.bindText($0, 1, aliasID) }) { stmt in
            group = self.columnText(stmt, 0)
        }
        return group
    }

    /// A share file → provider-agnostic ``MediaVersion``. The share has no server
    /// stream metadata, so the resolution is parsed from the filename and the
    /// basename is passed as `name` for the shared `EditionParser` to recover the
    /// edition (Director's Cut, …) and source quality (Remux/BluRay/WEB-DL). The
    /// version `id` is the file's rel-path, threaded back as the `mediaSourceID`.
    private static func movieVersion(relPath: String, basename: String, size: Int64) -> MediaVersion {
        MediaVersion(
            id: relPath,
            name: (basename as NSString).deletingPathExtension,
            height: resolutionHeight(fromName: basename),
            sizeBytes: size > 0 ? size : nil,
            videoRange: videoRange(fromName: basename),
            container: (basename as NSString).pathExtension.lowercased()
        )
    }

    /// Best-effort resolution height parsed from a filename token (`2160p`, `1080p`,
    /// `4K`, …). `nil` when the name states none.
    private static func resolutionHeight(fromName name: String) -> Int? {
        let l = name.lowercased()
        if l.contains("2160p") || l.contains("4k") || l.contains("uhd") { return 2160 }
        if l.contains("1440p") { return 1440 }
        if l.contains("1080p") || l.contains("1080i") { return 1080 }
        if l.contains("720p") { return 720 }
        if l.contains("576p") { return 576 }
        if l.contains("480p") { return 480 }
        return nil
    }

    /// Best-effort HDR range parsed from common release-name tokens. This makes
    /// SMB version rows distinguish a Dolby Vision file from its SDR sibling
    /// before the optional header probe has populated full stream metadata.
    private static func videoRange(fromName name: String) -> String? {
        let lower = name.lowercased()
        let compact = lower
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if compact.contains("dolbyvision") || tokens.contains("dovi") || tokens.contains("dv") {
            return HDRRange.dolbyVision.rawValue
        }
        if compact.contains("hdr10+") || compact.contains("hdr10plus") || compact.contains("hdr10") {
            return HDRRange.hdr10.rawValue
        }
        if compact.contains("hlg") { return HDRRange.hlg.rawValue }
        return nil
    }

    private func seriesItem(key: String, title: String, library: CatalogLibrary, year: Int?) -> MediaItem {
        MediaItem(
            id: ShareCatalogID.series(key),
            title: title,
            kind: .series,
            productionYear: year,
            seriesID: ShareCatalogID.series(key),
            libraryID: ShareCatalogID.library(library)
        )
    }

    /// Build an episode item from a row selecting
    /// `rel_path, title, [kind|series_title], ...` — the two episode query shapes
    /// share column *names*, so read episode fields by a fixed layout:
    /// col0 rel_path, col1 title, col2 series_title, col3 season, col4 episode,
    /// col5 library, col6 year (used by `episodes(...)`), OR the `item(id:)` layout.
    private func episodeItem(from stmt: OpaquePointer?, seriesKey: String) -> MediaItem {
        // Read by name-agnostic positions used by the two callers. To stay robust,
        // pull values via helper that tolerates either layout is overkill; instead
        // both callers pass compatible column orders. `episodes(...)`:
        //   0 rel_path,1 title,2 series_title,3 season,4 episode,5 library,6 year
        // `item(id:)`:
        //   0 rel_path,1 title,2 kind,3 library,4 year,5 series_title,6 series_key,7 season,8 episode
        let colCount = sqlite3_column_count(stmt)
        let relPath = columnText(stmt, 0) ?? ""
        let title = columnText(stmt, 1) ?? relPath
        var seriesTitle: String?
        var season: Int?
        var episode: Int?
        var library: CatalogLibrary = .tv
        if colCount <= 7 {
            seriesTitle = columnText(stmt, 2)
            season = columnOptInt(stmt, 3)
            episode = columnOptInt(stmt, 4)
            library = CatalogLibrary(rawValue: columnText(stmt, 5) ?? "tv") ?? .tv
        } else {
            library = CatalogLibrary(rawValue: columnText(stmt, 3) ?? "tv") ?? .tv
            seriesTitle = columnText(stmt, 5)
            season = columnOptInt(stmt, 7)
            episode = columnOptInt(stmt, 8)
        }
        return MediaItem(
            id: ShareCatalogID.file(relPath),
            title: title,
            kind: .episode,
            parentTitle: seriesTitle,
            seasonNumber: season,
            episodeNumber: episode,
            seriesID: ShareCatalogID.series(seriesKey),
            // Give the episode its season id (the provider's own `season:key:N`
            // scheme that `children(of:)` decodes) so the player's neighbour
            // resolver — gated on `kind == .episode && seasonID != nil` — engages
            // for SMB shares too, enabling auto-advance, the Up Next card, and the
            // next-episode prefetch. Without it SMB episodes never hand off.
            seasonID: season.map { ShareCatalogID.season(seriesKey, $0) },
            libraryID: ShareCatalogID.library(library)
        )
    }

    // MARK: - Small SQLite helpers

    private func count(where clause: String?) -> Int {
        ensureOpen()
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM assets" + (clause.map { " WHERE \($0)" } ?? "") + ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func distinctSeriesCount(library: CatalogLibrary) -> Int {
        ensureOpen()
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT series_key) FROM assets WHERE library=? AND kind='episode' AND series_key IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, library.rawValue)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Whether `table` already has `column` — drives one-shot column migrations.
    /// `table`/`column` are compile-time literals at every call site, so the
    /// interpolation into the PRAGMA carries no injection risk.
    private func hasColumn(table: String, column: String) -> Bool {
        var found = false
        query("PRAGMA table_info(\(table));") { stmt in
            if self.columnText(stmt, 1) == column { found = true }
        }
        return found
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.transient)
    }
    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindOptInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, idx, Int64(value)) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
    private func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double {
        sqlite3_column_double(stmt, idx)
    }
    private func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, idx))
    }

    // MARK: - Location / naming (mirrors ShareWatchStore)

    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Plozz", isDirectory: true)
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(mapped.prefix(80))-\(String(hash, radix: 16))"
    }
}
