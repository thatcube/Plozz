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

    // SQLite wants a destructor sentinel for transient (copied) bound text; not
    // exported into Swift, so reconstruct it.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        // Migration: movie grouping key (added with within-share version dedup). NULL
        // for rows indexed before it existed; a classifier-version reparse backfills
        // it, and grouped queries `COALESCE(movie_key, rel_path)` so pre-reparse rows
        // each stand alone rather than collapsing into one NULL bucket.
        if !hasColumn(table: "assets", column: "movie_key") {
            exec("ALTER TABLE assets ADD COLUMN movie_key TEXT;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_assets_movie_key ON assets(library, kind, movie_key);")
    }

    // MARK: - Scan write path

    /// Insert or update a batch of discovered assets under one scan id. Preserves
    /// `first_seen_at` for rows already present (so "date added" = first discovery,
    /// never a re-scan), and refreshes size/mtime/parse/library. Idempotent.
    func upsert(_ assets: [CatalogAsset], scanID: Int64, now: Date = Date()) {
        ensureOpen()
        guard db != nil, !assets.isEmpty else { return }
        exec("BEGIN IMMEDIATE;")
        let sql = """
        INSERT INTO assets
          (rel_path, basename, size, modified_at, first_seen_at, last_scan,
           kind, library, title, sort_title, year, series_title, series_key, season, episode, movie_key)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          basename=excluded.basename, size=excluded.size, modified_at=excluded.modified_at,
          last_scan=excluded.last_scan, kind=excluded.kind, library=excluded.library,
          title=excluded.title, sort_title=excluded.sort_title, year=excluded.year,
          series_title=excluded.series_title, series_key=excluded.series_key,
          season=excluded.season, episode=excluded.episode, movie_key=excluded.movie_key;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;"); return
        }
        defer { sqlite3_finalize(stmt) }
        for a in assets {
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
            bindText(stmt, 10, a.title.lowercased())
            bindOptInt(stmt, 11, a.year)
            bindOptText(stmt, 12, a.seriesTitle)
            bindOptText(stmt, 13, a.seriesKey)
            bindOptInt(stmt, 14, a.season)
            bindOptInt(stmt, 15, a.episode)
            bindOptText(stmt, 16, a.movieKey)
            _ = sqlite3_step(stmt)
        }
        exec("COMMIT;")
    }

    /// Delete rows not seen by `scanID` — assets removed from the share since the
    /// last full walk. Only call after a scan that fully completed (no cancel), so
    /// a partial walk can't wipe still-present content.
    func pruneNotSeen(inScan scanID: Int64) {
        ensureOpen()
        guard db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM assets WHERE last_scan <> ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, scanID)
        _ = sqlite3_step(stmt)
    }

    func setMeta(_ key: String, _ value: String) {
        ensureOpen()
        guard db != nil else { return }
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
            SELECT a.series_key, a.series_title, a.library, MAX(a.year) FROM assets a
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
            var rep: String?
            query("SELECT MIN(rel_path) FROM assets WHERE movie_key=? AND library='movies' AND kind='movie';",
                  bind: { self.bindText($0, 1, mkey) }) { stmt in rep = self.columnText(stmt, 0) }
            guard let rep else { return nil }
            return pendingEnrichment(forItemID: ShareCatalogID.file(rep), version: version)
        }

        // Series → the enrichment row is keyed by `series:<key>`.
        if ShareCatalogID.isSeries(id), let key = ShareCatalogID.seriesKey(forSeriesID: id) {
            let itemID = ShareCatalogID.series(key)
            if hasUsableEnrichment(itemID: itemID, version: version) { return nil }
            var out: PendingEnrichment?
            query("SELECT series_title, library, MAX(year) FROM assets WHERE series_key=? AND kind='episode';",
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
          (item_id, provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url, enriched_at, enrich_version, attempts)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(item_id) DO UPDATE SET
          provider_ids_json=excluded.provider_ids_json, overview=excluded.overview,
          genres_json=excluded.genres_json, runtime=excluded.runtime,
          poster_url=excluded.poster_url, backdrop_url=excluded.backdrop_url,
          logo_url=excluded.logo_url, enriched_at=excluded.enriched_at,
          enrich_version=excluded.enrich_version, attempts=excluded.attempts;
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
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)

        // Anime confirmation: an AniList/MAL id (from either the new or existing
        // record) proves this series is anime.
        if ok, ShareCatalogID.isSeries(itemID),
           let key = ShareCatalogID.seriesKey(forSeriesID: itemID),
           merged.providerIDs.keys.contains(where: { ["anilist", "mal", "myanimelist"].contains($0.lowercased()) }) {
            reclassifySeriesToAnime(seriesKey: key)
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

    /// Persisted enrichment for a catalog id (movie file id or `series:<key>`).
    private func enrichmentRow(itemID: String) -> EnrichmentRecord? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url
        FROM enrichment WHERE item_id=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return enrichmentRecord(fromColumns: stmt, startingAt: 0)
    }

    /// Decode the 7 enrichment columns (provider_ids_json, overview, genres_json,
    /// runtime, poster_url, backdrop_url, logo_url) starting at `startingAt` into a
    /// record. Shared by the standalone `enrichmentRow` lookup and the JOINed grid
    /// queries (movies/series), so a page fetch reads enrichment in ONE query instead
    /// of N+1 per-row lookups. Returns nil when every column is NULL (no enrichment
    /// row matched the LEFT JOIN).
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
        var rep: String?
        query("SELECT 'f:' || MIN(rel_path) FROM assets WHERE movie_key=? AND library='movies' AND kind='movie';",
              bind: { self.bindText($0, 1, mkey) }) { stmt in rep = self.columnText(stmt, 0) }
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
          CASE WHEN MIN(movie_key) IS NOT NULL THEN 'movie:' || MIN(movie_key)
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year), MIN(first_seen_at) AS added
        FROM assets WHERE library='movies' AND kind='movie'
        GROUP BY COALESCE(movie_key, rel_path)
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
          CASE WHEN MIN(movie_key) IS NOT NULL THEN 'movie:' || MIN(movie_key)
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year)
        FROM assets
        WHERE library='movies' AND kind='movie' AND sort_title LIKE ?
        GROUP BY COALESCE(movie_key, rel_path) LIMIT ?;
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
               e.poster_url, e.backdrop_url, e.logo_url
        FROM (
          SELECT
            CASE WHEN MIN(movie_key) IS NOT NULL THEN 'movie:' || MIN(movie_key)
                 ELSE 'f:' || MIN(rel_path) END AS logical_id,
            'f:' || MIN(rel_path) AS rep_id,
            MIN(title) AS title, MAX(year) AS year, MIN(sort_title) AS gsort
          FROM assets WHERE library='movies' AND kind='movie'
          GROUP BY COALESCE(movie_key, rel_path)
        ) g
        LEFT JOIN enrichment e ON e.item_id = g.rep_id
        ORDER BY g.gsort LIMIT ? OFFSET ?;
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
        SELECT a.series_key, a.series_title, MAX(a.year), MIN(a.sort_title) AS s,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url
        FROM assets a
        LEFT JOIN enrichment e ON e.item_id = 'series:' || a.series_key
        WHERE a.library=? AND a.kind='episode' AND a.series_key IS NOT NULL
        GROUP BY a.series_key ORDER BY s LIMIT ? OFFSET ?;
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
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT COALESCE(movie_key, rel_path)) FROM assets WHERE library='movies' AND kind='movie';", -1, &stmt, nil) == SQLITE_OK else { return 0 }
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
        SELECT DISTINCT COALESCE(season,1) AS s, series_title, library FROM assets
        WHERE series_key=? AND kind='episode' ORDER BY s;
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            seasons.append(Int(sqlite3_column_int64(stmt, 0)))
            if let t = self.columnText(stmt, 1) { seriesTitle = t }
            library = CatalogLibrary(rawValue: self.columnText(stmt, 2) ?? "tv") ?? .tv
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

    /// Episode items for one season of a series, in episode order.
    func episodes(seriesKey: String, season: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT rel_path, title, series_title, season, episode, library, year FROM assets
        WHERE series_key=? AND kind='episode' AND COALESCE(season,1)=?
        ORDER BY COALESCE(episode, 999999), sort_title;
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
            query("SELECT series_title, library, MAX(year) FROM assets WHERE series_key=? AND kind='episode';",
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
            SELECT rel_path, title, kind, library, year, series_title, series_key, season, episode
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
                        libraryID: ShareCatalogID.moviesLibrary
                    )
                }
            }
            return result.map(withEnrichment)
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
        var files: [(relPath: String, basename: String, size: Int64)] = []
        var title: String?
        var year: Int?
        query("""
        SELECT rel_path, basename, size, title, year FROM assets
        WHERE movie_key=? AND library='movies' AND kind='movie' ORDER BY rel_path;
        """, bind: { self.bindText($0, 1, key) }) { stmt in
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
            id: ShareCatalogID.movie(key),
            title: title ?? key,
            kind: .movie,
            productionYear: year,
            libraryID: ShareCatalogID.moviesLibrary,
            // Cards/rows leave versions empty; only the detail item carries them.
            // A lone file needs no picker, so expose versions only when there's a
            // genuine choice.
            versions: versions.count > 1 ? versions : []
        )
        return withEnrichment(item)
    }

    /// The best default file to play for a logical movie when the caller named no
    /// specific version (play-from-card, before the detail's version picker set
    /// one): the highest parsed resolution, then the largest file.
    func defaultMovieRelPath(forKey key: String) -> String? {
        var best: (rel: String, height: Int, size: Int64)?
        query("SELECT rel_path, basename, size FROM assets WHERE movie_key=? AND library='movies' AND kind='movie';",
              bind: { self.bindText($0, 1, key) }) { stmt in
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
        guard let rel = ShareCatalogID.relPath(forFileID: id) else { return id }
        var key: String?
        query("SELECT movie_key FROM assets WHERE rel_path=? AND kind='movie';",
              bind: { self.bindText($0, 1, rel) }) { stmt in key = self.columnText(stmt, 0) }
        if let key { return ShareCatalogID.movie(key) }
        return id
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
