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
        exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
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
           kind, library, title, sort_title, year, series_title, series_key, season, episode)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          basename=excluded.basename, size=excluded.size, modified_at=excluded.modified_at,
          last_scan=excluded.last_scan, kind=excluded.kind, library=excluded.library,
          title=excluded.title, sort_title=excluded.sort_title, year=excluded.year,
          series_title=excluded.series_title, series_key=excluded.series_key,
          season=excluded.season, episode=excluded.episode;
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

        // Movies
        query("""
        SELECT rel_path, title, year, first_seen_at FROM assets
        WHERE library='movies' AND kind='movie' ORDER BY first_seen_at DESC LIMIT ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            let relPath = self.columnText(stmt, 0) ?? ""
            let item = MediaItem(
                id: ShareCatalogID.file(relPath),
                title: self.columnText(stmt, 1) ?? relPath,
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

        return out.sorted { $0.added > $1.added }.prefix(limit).map(\.item)
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
        SELECT rel_path, title, year FROM assets
        WHERE library='movies' AND kind='movie' AND sort_title LIKE ? LIMIT ?;
        """, bind: {
            self.bindText($0, 1, needle); sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            let relPath = self.columnText(stmt, 0) ?? ""
            out.append(MediaItem(
                id: ShareCatalogID.file(relPath),
                title: self.columnText(stmt, 1) ?? relPath,
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

        return Array(out.prefix(limit))
    }

    /// Movie items for the Movies library grid (paged).
    func movies(offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT rel_path, title, year FROM assets
        WHERE library='movies' AND kind='movie' ORDER BY sort_title LIMIT ? OFFSET ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)); sqlite3_bind_int64($0, 2, Int64(offset)) }) { stmt in
            let relPath = self.columnText(stmt, 0) ?? ""
            out.append(MediaItem(
                id: ShareCatalogID.file(relPath),
                title: self.columnText(stmt, 1) ?? relPath,
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            ))
        }
        return out
    }

    /// Distinct series items for a TV/Anime library, alphabetical.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen()
        guard db != nil, library != .movies else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT series_key, series_title, MAX(year), MIN(sort_title) AS s FROM assets
        WHERE library=? AND kind='episode' AND series_key IS NOT NULL
        GROUP BY series_key ORDER BY s LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit)); sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            out.append(self.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: library, year: self.columnOptInt(stmt, 2)))
        }
        return out
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
        }
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
        return out
    }

    /// Resolve any catalog id to a rich `MediaItem`, or `nil` if unknown here
    /// (caller falls back to the raw browser for `share:root` / `d:` ids).
    func item(id: String) -> MediaItem? {
        ensureOpen()
        guard db != nil else { return nil }
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
            return found ? seriesItem(key: key, title: title, library: library, year: year) : nil
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
            return result
        }
        return nil
    }

    // MARK: - Item builders

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
