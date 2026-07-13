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
    private let url: URL
    private var db: OpaquePointer?
    private var didOpen = false
    private var activeScanGeneration: UUID?

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
    init(accountKey: String, directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("share-catalog-\(Self.sanitize(accountKey)).sqlite")
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
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
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
            episode     INTEGER
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_assets_lib ON assets(library, kind);")
        exec("CREATE INDEX IF NOT EXISTS idx_assets_series ON assets(series_key, season, episode);")
        exec("CREATE INDEX IF NOT EXISTS idx_assets_added ON assets(first_seen_at DESC);")
        // Covers the Movies grid query (WHERE library, kind ORDER BY sort_title) so
        // the sort is index-provided instead of a per-page temp B-tree sort.
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movies_sort ON assets(library, kind, sort_title);")
        exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
        // Per-logical-item enrichment (resolved at scan time by ShareEnricher and
        // persisted): external ids for merge/ratings/Trakt, plus overview + artwork
        // URLs so detail/cards are rich without a live lookup. Keyed by the item's
        // catalog id ("f:<relpath>" for movies, "series:<key>" for series).
        exec("""
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
            enrich_version INTEGER NOT NULL
        );
        """)
        // Migration: bounded-retry attempt counter (added after first ship). Guarded
        // so it runs at most once; `exec` ignores the "duplicate column" error too.
        if !hasColumn(table: "enrichment", column: "attempts") {
            exec("ALTER TABLE enrichment ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;")
        }
        // Migration: the resolved canonical title (e.g. "Avatar: The Last Airbender"),
        // applied over a generic folder-derived display title at READ time — durable
        // across re-scans (which overwrite `assets.series_title`), unlike a direct
        // assets mutation.
        if !hasColumn(table: "enrichment", column: "title") {
            exec("ALTER TABLE enrichment ADD COLUMN title TEXT;")
        }
        // Migration: movie grouping key (added with within-share version dedup). NULL
        // for rows indexed before it existed; a classifier-version reparse backfills
        // it, and grouped queries `COALESCE(movie_key, rel_path)` so pre-reparse rows
        // each stand alone rather than collapsing into one NULL bucket.
        if !hasColumn(table: "assets", column: "movie_key") {
            exec("ALTER TABLE assets ADD COLUMN movie_key TEXT;")
        }
        if !hasColumn(table: "assets", column: "movie_title_key") {
            exec("ALTER TABLE assets ADD COLUMN movie_title_key TEXT;")
        }
        if !hasColumn(table: "assets", column: "movie_group_key") {
            exec("ALTER TABLE assets ADD COLUMN movie_group_key TEXT;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movie_key ON assets(library, kind, movie_key);")
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movie_group ON assets(library, kind, movie_group_key);")
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movie_key_direct ON assets(movie_key);")
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movie_group_direct ON assets(movie_group_key);")
        exec("""
        CREATE TABLE IF NOT EXISTS movie_alias(
            alias_id  TEXT PRIMARY KEY,
            group_key TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_movie_alias_group ON movie_alias(group_key);")
        // Durable series reconciliation: maps a redundant series key (e.g. a typo'd
        // folder "peaky-blinder") to a canonical one ("peaky-blinders") once BOTH
        // were proven the same show by a shared authoritative external id. Applied at
        // upsert so a re-scan can't undo the merge.
        exec("""
        CREATE TABLE IF NOT EXISTS series_merge(
            alias_key     TEXT PRIMARY KEY,
            canonical_key TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_series_merge_canonical ON series_merge(canonical_key);")
        exec("""
        CREATE INDEX IF NOT EXISTS idx_assets_movie_logical_sort
        ON assets(
          library, kind,
          COALESCE(movie_group_key, movie_key, rel_path),
          sort_title
        );
        """)
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
           movie_key, movie_title_key)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          basename=excluded.basename, size=excluded.size, modified_at=excluded.modified_at,
          last_scan=excluded.last_scan, kind=excluded.kind, library=excluded.library,
          title=excluded.title, sort_title=excluded.sort_title, year=excluded.year,
          series_title=excluded.series_title, series_key=excluded.series_key,
          season=excluded.season, episode=excluded.episode, movie_key=excluded.movie_key,
          movie_title_key=excluded.movie_title_key,
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

        /// Whether this record carries anything worth showing/merging. An *unusable*
        /// result (no ids, overview, or artwork) is treated as a miss — usually a
        /// transient rate-limit/timeout — and is retried across passes rather than
        /// cached as a permanent blank.
        var isUsable: Bool {
            !providerIDs.isEmpty
                || (overview?.isEmpty == false)
                || posterURL != nil || backdropURL != nil || logoURL != nil
        }
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
    func pendingEnrichment(version: Int, limit: Int) -> [PendingEnrichment] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [PendingEnrichment] = []

        // Movies: a movie asset is pending when it has no current-version enrichment
        // row, OR its row is an unusable miss still under the retry cap.
        query("""
        SELECT a.rel_path, a.title, a.year FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'f:' || a.rel_path AND e.enrich_version = ?
        WHERE a.library='movies' AND a.kind='movie'
          AND (e.item_id IS NULL OR (\(Self.unusableEnrichmentPredicate) AND e.attempts < ?))
        ORDER BY a.first_seen_at LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(version))
            sqlite3_bind_int64($0, 2, Int64(Self.maxEnrichAttempts))
            sqlite3_bind_int64($0, 3, Int64(limit))
        }) { stmt in
            let relPath = self.columnText(stmt, 0) ?? ""
            out.append(PendingEnrichment(
                itemID: ShareCatalogID.file(relPath),
                title: self.columnText(stmt, 1) ?? relPath,
                year: self.columnOptInt(stmt, 2),
                isMovie: true, isAnime: false
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
            ) FROM assets a
            LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key AND e.enrich_version = ?
            WHERE a.kind='episode' AND a.series_key IS NOT NULL
              AND (e.item_id IS NULL OR (\(Self.unusableEnrichmentPredicate) AND e.attempts < ?))
            GROUP BY a.series_key ORDER BY MIN(a.first_seen_at) LIMIT ?;
            """, bind: {
                sqlite3_bind_int64($0, 1, Int64(version))
                sqlite3_bind_int64($0, 2, Int64(Self.maxEnrichAttempts))
                sqlite3_bind_int64($0, 3, Int64(remaining))
            }) { stmt in
                guard let key = self.columnText(stmt, 0) else { return }
                let lib = self.columnText(stmt, 2) ?? "tv"
                out.append(PendingEnrichment(
                    itemID: ShareCatalogID.series(key),
                    title: self.columnText(stmt, 1) ?? key,
                    year: self.columnOptInt(stmt, 3),
                    isMovie: false, isAnime: lib == "anime"
                ))
            }
        }
        return out
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
            ) FROM assets WHERE series_key=?1 AND kind='episode' LIMIT 1;
            """,
                  bind: { self.bindText($0, 1, key) }) { stmt in
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
                let lib = self.columnText(stmt, 1) ?? "tv"
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? key,
                    year: self.columnOptInt(stmt, 2),
                    isMovie: false, isAnime: lib == "anime"
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
            query("SELECT title, year, kind FROM assets WHERE rel_path=?;",
                  bind: { self.bindText($0, 1, relPath) }) { stmt in
                guard (self.columnText(stmt, 2) ?? "movie") == "movie" else { return }
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? relPath,
                    year: self.columnOptInt(stmt, 1),
                    isMovie: true, isAnime: false
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
        guard db != nil else { return false }

        // Merge onto the existing row (if any) so a sparse write never clobbers
        // richer data. An unusable (empty) resolve — usually a transient rate-limit
        // or timeout — bumps an attempt counter but is still stored at `version`;
        // `pendingEnrichment` keeps such rows pending until `attempts` reach the cap,
        // so a miss is retried across passes and then settled, never cached as a
        // permanent blank and never looped forever.
        let merged = Self.merged(existing: enrichmentRow(itemID: itemID), new: record)
        // Attempt budget is PER VERSION: a future `ShareEnricher.version` bump (the
        // mechanism to re-enrich everything with improved sources) resets the budget
        // so a previously-exhausted miss gets the full retry count again, not one.
        // Within the same version the count accrues as before.
        let prior = enrichmentVersionAndAttempts(itemID: itemID)
        let priorAttempts = (prior?.version == version) ? (prior?.attempts ?? 0) : 0
        let attempts = merged.isUsable ? 0 : priorAttempts + 1

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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
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
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)

        // Anime confirmation: an AniList/MAL id (from either the new or existing
        // record) proves this series is anime.
        if ok, ShareCatalogID.isSeries(itemID),
           let key = ShareCatalogID.seriesKey(forSeriesID: itemID),
           merged.providerIDs.keys.contains(where: { ["anilist", "mal", "myanimelist"].contains($0.lowercased()) }) {
            reclassifySeriesToAnime(seriesKey: key)
        }
        // Id-corroborated reconciliation: if this series shares an authoritative
        // external id with another near-identically-titled series (a typo'd folder
        // like "Peaky Blinder" vs "Peaky Blinders"), fold them into one card.
        if ok, ShareCatalogID.isSeries(itemID),
           let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            reconcileSeriesByStrongID(key: key, ids: merged.providerIDs, resolvedTitle: merged.title)
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
            for (k, v) in new.providerIDs where !v.isEmpty { ids[k] = v }
            out.providerIDs = ids
        }
        if let o = new.overview, !o.isEmpty { out.overview = o }
        if !new.genres.isEmpty { out.genres = new.genres }
        if let r = new.runtime { out.runtime = r }
        if let p = new.posterURL { out.posterURL = p }
        if let b = new.backdropURL { out.backdropURL = b }
        if let l = new.logoURL { out.logoURL = l }
        if let t = new.title, !t.isEmpty { out.title = t }
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

    private func reclassifySeriesToAnime(seriesKey: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE assets SET library='anime' WHERE series_key=? AND kind='episode' AND library<>'anime';", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, seriesKey)
        _ = sqlite3_step(stmt)
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
    private func reconcileSeriesByStrongID(key: String, ids: [String: String], resolvedTitle: String?) {
        guard db != nil else { return }
        let myStrong = Self.strongIDNamespaces.compactMap { ns -> (String, String)? in
            guard let v = ids[ns], !v.isEmpty else { return nil }
            return (ns.lowercased(), v.lowercased())
        }
        guard !myStrong.isEmpty else { return }
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
        guard !candidates.isEmpty else { return }

        let myTitle = seriesDisplayTitle(forKey: key)
        for other in candidates {
            let otherTitle = seriesDisplayTitle(forKey: other)
            guard Self.titlesNearlyIdentical(myTitle, otherTitle) else { continue }
            let (canonical, loser) = chooseCanonicalSeries(key, other, resolvedTitle: resolvedTitle)
            mergeSeries(loser: loser, into: canonical)
        }
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
    private func mergeSeries(loser: String, into canonical: String) {
        guard loser != canonical else { return }
        exec("BEGIN IMMEDIATE;")
        runUpdate("UPDATE assets SET series_key=? WHERE series_key=?;") { self.bindText($0, 1, canonical); self.bindText($0, 2, loser) }
        runUpdate("INSERT OR REPLACE INTO series_merge(alias_key, canonical_key) VALUES (?,?);") { self.bindText($0, 1, loser); self.bindText($0, 2, canonical) }
        runUpdate("UPDATE series_merge SET canonical_key=? WHERE canonical_key=?;") { self.bindText($0, 1, canonical); self.bindText($0, 2, loser) }
        runUpdate("DELETE FROM enrichment WHERE item_id=?;") { self.bindText($0, 1, ShareCatalogID.series(loser)) }
        exec("COMMIT;")
    }

    /// Run a parameterized write statement with a binder; finalizes cleanly.
    private func runUpdate(_ sql: String, bind: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        _ = sqlite3_step(stmt)
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
        return enrichmentRecord(fromColumns: stmt, startingAt: 0)
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
        let key: String
        switch item.kind {
        case .series:
            key = item.id
        case .movie:
            // A grouped movie (`movie:<key>`) stores its enrichment under the
            // group's REPRESENTATIVE file id (`f:<MIN(rel_path)>`) — where the
            // per-file enrichment pass already wrote art/ids — so resolve to that.
            // A legacy un-grouped `f:` movie id is its own enrichment key.
            key = movieEnrichmentKey(forID: item.id)
        case .season, .episode:
            guard let seriesID = item.seriesID else { return item }
            key = seriesID
        default:
            return item
        }
        guard let rec = enrichmentRow(itemID: key) else { return item }
        return applyEnrichment(item, rec)
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
        // Merge ids (don't clobber any already present).
        if !rec.providerIDs.isEmpty {
            var ids = copy.providerIDs
            for (k, v) in rec.providerIDs where ids[k] == nil { ids[k] = v }
            copy.providerIDs = ids
        }
        if (copy.overview?.isEmpty ?? true), item.kind != .episode { copy.overview = rec.overview }
        if copy.genres.isEmpty { copy.genres = rec.genres }
        if copy.runtime == nil, let rt = rec.runtime, item.kind == .movie { copy.runtime = rt }
        if copy.posterURL == nil { copy.posterURL = rec.posterURL }
        if copy.backdropURL == nil { copy.backdropURL = rec.backdropURL }
        if copy.heroBackdropURL == nil { copy.heroBackdropURL = rec.backdropURL }
        if copy.logoURL == nil { copy.logoURL = rec.logoURL }
        // Display-title upgrade (series/movies only, never episodes): overlay the
        // resolved canonical name when it's IDENTICAL, MORE SPECIFIC (current is a
        // word-prefix of resolved), or a NEAR-IDENTICAL typo/plural of the current
        // ("Peaky Blinder" → "Peaky Blinders") — so a generic or misspelled folder
        // shows the real name, but a spinoff that wrongly matched its parent is never
        // renamed DOWN. Applied at READ time so it's durable across re-scans.
        if item.kind == .series || item.kind == .movie,
           let resolved = rec.title, !resolved.isEmpty, resolved != copy.title {
            let a = MediaItemIdentity.normalizedTitle(copy.title)
            let b = MediaItemIdentity.normalizedTitle(resolved)
            if b == a || b.hasPrefix(a + " ") || Self.titlesNearlyIdentical(copy.title, resolved) {
                copy.title = resolved
            }
        }
        // Episodes get the series art as a fallback, not as their own poster.
        if item.kind == .episode {
            if copy.seriesPosterURL == nil { copy.seriesPosterURL = rec.posterURL }
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

        return out.sorted { $0.added > $1.added }.prefix(limit).map(\.item).map(withEnrichment)
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

        return Array(out.prefix(limit)).map(withEnrichment)
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
        var out: [MediaItem] = []
        query("""
        SELECT g.logical_id, g.title, g.year,
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
        ORDER BY g.gsort, g.title, g.logical_id LIMIT ? OFFSET ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)); sqlite3_bind_int64($0, 2, Int64(offset)) }) { stmt in
            let item = MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            )
            if let rec = self.enrichmentRecord(fromColumns: stmt, startingAt: 3) {
                out.append(self.applyEnrichment(item, rec))
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// Distinct series items for a TV/Anime library, alphabetical.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil, library != .movies else { return [] }
        var out: [MediaItem] = []
        // LEFT JOIN enrichment (keyed "series:<series_key>") into the grouped query so
        // a page is one query, not 1 + N per-row enrichment lookups. The GROUP BY is
        // over series_key, which the JOIN is 1:1 with.
        query("""
        SELECT a.series_key, MIN(a.series_title), MAX(a.year), MIN(a.sort_title) AS s,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url, e.title
        FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key
        WHERE a.library=? AND a.kind='episode' AND a.series_key IS NOT NULL
        GROUP BY a.series_key ORDER BY s, a.series_key LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit)); sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let item = self.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: library, year: self.columnOptInt(stmt, 2))
            if let rec = self.enrichmentRecord(fromColumns: stmt, startingAt: 4) {
                out.append(self.applyEnrichment(item, rec))
            } else {
                out.append(item)
            }
        }
        return out
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
        return seasons.map { n in
            MediaItem(
                id: ShareCatalogID.season(seriesKey, n),
                title: "Season \(n)",
                kind: .season,
                parentTitle: seriesTitle,
                seasonNumber: n,
                seriesID: ShareCatalogID.series(seriesKey),
                libraryID: ShareCatalogID.library(library)
            )
        }.map(withEnrichment)
    }

    /// Up to `limit` on-disk episode fingerprints (season, episode, title) for a
    /// series — the earliest seasons/episodes with a real title — used to
    /// disambiguate a same-name metadata collision by content. Skips episodes with
    /// no parsed title (nothing to match on).
    func episodeTitleHints(seriesKey: String, limit: Int = 12) -> [(season: Int, episode: Int, title: String)] {
        ensureOpen()
        guard db != nil, limit > 0 else { return [] }
        var out: [(season: Int, episode: Int, title: String)] = []
        query("""
        SELECT COALESCE(season,1) AS s, episode, title FROM assets
        WHERE series_key=? AND kind='episode' AND episode IS NOT NULL
          AND title IS NOT NULL AND title <> ''
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
        var seen = Set<String>()
        var alternates: [String] = []
        for path in relPaths {
            guard let title = ShareMediaParser.filenameSeriesTitle(relPath: path) else { continue }
            let norm = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
            guard !norm.isEmpty, norm != storedNorm, seen.insert(norm).inserted else { continue }
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
        return out.map(withEnrichment)
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

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
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
