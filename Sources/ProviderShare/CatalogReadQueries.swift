import Foundation
import SQLite3
import CoreModels
import CoreNetworking

/// Reference box for the store's "does this catalog have ANY local (NFO/filename)
/// metadata at all" memo. It lets the read-query helper share — and lazily populate —
/// the *exact same* cached flag that `ShareCatalogStore`'s write paths invalidate, so
/// the "no real query on every read-path call for the common no-NFO catalog"
/// optimization is preserved without the store re-implementing the read cluster.
/// Only ever touched under the store actor's isolation (all reads are serialized), so
/// the shared mutable flag races nothing.
final class LocalMetadataPresence {
    var cached: Bool?
    init(_ cached: Bool? = nil) { self.cached = cached }
}

/// Pure, synchronous, transaction-free **read-query composition** for one share
/// catalog, running over the store-owned, actor-confined `CatalogConnection`. It owns
/// the catalog *read path* — the `MediaItem`-building queries the Home grid, search,
/// detail, seasons/episodes, and watch-state stamping issue — plus the persisted
/// enrichment/local-metadata overlay that decorates those items, the movie-grouping
/// resolution reads, and the small assets-count intents. It depends only on the
/// connection plus module-level pure types (`ShareCatalogReadProjection`,
/// `ShareCatalogID`, `ShareMediaParser`, `EnrichmentRepository`, and the enrichment
/// DTOs), never on `ShareCatalogStore`.
///
/// A cheap value type constructed on demand by the store; it holds no independent
/// mutable lifecycle state, actor, queue, or SQLite connection, and never opens a
/// transaction. `normalizedMetadataReady` is a value snapshot supplied by the store
/// (reads are serialized on the store actor, so it equals the live value for the
/// duration of one read), and the "has any local metadata" memo is shared via the
/// store-owned `LocalMetadataPresence` box. The store's public read methods forward
/// here after `ensureOpen()`, so these bodies assume an already-open connection.
struct CatalogReadQueries {
    let connection: CatalogConnection
    /// Value snapshot of the store's `normalizedMetadataReady` — whether the local
    /// metadata materialization has completed and normalized winners may be overlaid.
    let normalizedMetadataReady: Bool
    /// Shared, store-owned memo for `hasAnyLocalMetadata()` (invalidated by store writes).
    let localMetadataPresence: LocalMetadataPresence

    /// Bridge so the moved raw `sqlite3_*` call sites read the connection's handle
    /// unchanged; the connection owns its lifetime (open/close), which the store's
    /// forwarders guarantee before delegating here.
    private var db: OpaquePointer? { connection.db }

    /// Leaf enrichment persistence over the same actor-confined connection — used only
    /// for the `hasUsableEnrichment` fast-path check inside `pendingEnrichment`.
    private var enrichmentRepo: EnrichmentRepository { EnrichmentRepository(connection: connection) }

    // MARK: - Read path (build MediaItems)

    /// Whether the catalog has any indexed content yet (false on a fresh share
    /// before the first scan populates it).
    func isEmpty() -> Bool { count(where: nil) == 0 }

    /// Per-library counts so `libraries()` can hide an indexed library that has no
    /// content yet (movies = files; tv/anime = distinct series).
    func libraryCounts() -> (movies: Int, tvSeries: Int, animeSeries: Int) {
        let movies = count(where: "library='movies' AND kind='movie'")
        let tv = distinctSeriesCount(library: .tv)
        let anime = distinctSeriesCount(library: .anime)
        return (movies, tv, anime)
    }

    /// Recently added: movies + one entry per series (stamped with the series'
    /// newest episode discovery time), newest first. Non-network — Home hot path safe.
    func latest(limit: Int) -> [MediaItem] {
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
            out.append((self.columnDouble(stmt, 3), ShareCatalogReadProjection.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: lib, year: self.columnOptInt(stmt, 4))))
        }

        return withEnrichment(
            out.sorted { $0.added > $1.added }.prefix(limit).map(\.item)
        )
    }

    /// Free-text search across movie/episode titles and series titles. `LIKE` is
    /// fine at share scale (a few thousand rows) and stays index-light; FTS is a
    /// later refinement. Returns movie + series items.
    func search(query q: String, limit: Int) -> [MediaItem] {
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
            out.append(ShareCatalogReadProjection.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: lib, year: self.columnOptInt(stmt, 3)))
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
        ORDER BY COALESCE(CASE WHEN json_valid(sv.value_json) THEN json_extract(sv.value_json, '$') END, g.gsort), g.title, g.logical_id
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
                ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(rows.map { row in
            hydrated[row.enrichmentID].map { ShareCatalogReadProjection.applyEnrichment(row.item, $0) } ?? row.item
        })
    }

    /// Distinct series items for a TV/Anime library, alphabetical.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
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
        ORDER BY COALESCE(CASE WHEN json_valid(MIN(sv.value_json)) THEN json_extract(MIN(sv.value_json), '$') END, s), a.series_key
        LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit)); sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let item = ShareCatalogReadProjection.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: library, year: self.columnOptInt(stmt, 2))
            rows.append((
                item,
                ShareCatalogID.series(key),
                ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(rows.map { row in
            hydrated[row.enrichmentID].map { ShareCatalogReadProjection.applyEnrichment(row.item, $0) } ?? row.item
        })
    }

    /// Exact number of movies in the Movies library, for the grid's `totalCount`
    /// so it can size its sparse backing store once and random-access any page
    /// (jump-to-bottom). Counts DISTINCT logical movies (grouped by `movie_key`,
    /// falling back to `rel_path` for un-keyed rows) to match `movies()`.
    func movieCount() -> Int {
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

    /// On-disk episode-title fingerprints for content-based series disambiguation.
    /// EXCLUDES the synthetic `S<n>·E<nn>` placeholder titles that bare-numbered
    /// files get (they carry no real title) — otherwise a show whose early seasons
    /// are bare-numbered (Outlander) would send only useless placeholders and match
    /// nothing, falling through to a wrong same-named show. Real titles from any
    /// season are used instead.
    func episodeTitleHints(seriesKey: String, limit: Int = 12) -> [(season: Int, episode: Int, title: String)] {
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

    func episodes(seriesKey: String, season: Int) -> [MediaItem] {
        guard db != nil else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT rel_path, title, series_title, season, episode, library, year FROM assets
        WHERE series_key=? AND kind='episode' AND COALESCE(season,1)=?
        ORDER BY COALESCE(episode, 999999), sort_title, rel_path;
        """, bind: { self.bindText($0, 1, seriesKey); sqlite3_bind_int64($0, 2, Int64(season)) }) { stmt in
            out.append(ShareCatalogReadProjection.episodeItem(from: stmt, seriesKey: seriesKey))
        }
        return withEnrichment(out)
    }

    /// Resolve any catalog id to a rich `MediaItem`, or `nil` if unknown here
    /// (caller falls back to the raw browser for `share:root` / `d:` ids).
    func item(id: String) -> MediaItem? {
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
            return found ? withEnrichment(ShareCatalogReadProjection.seriesItem(key: key, title: title, library: library, year: year)) : nil
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
                    result = ShareCatalogReadProjection.episodeItem(from: stmt, seriesKey: self.columnText(stmt, 6) ?? "")
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
        guard db != nil, let relPath = ShareCatalogID.relPath(forFileID: id) else { return false }
        var found = false
        query("SELECT 1 FROM assets WHERE rel_path=? LIMIT 1;",
              bind: { self.bindText($0, 1, relPath) }) { _ in found = true }
        return found
    }

    /// Resolve a pre-grouping `movie:<movie_key>` id to its persisted logical
    /// group. Keeps v3 Continue Watching records, deep links, and queued watch
    /// writes working after v4 combines adjacent-year variants.
    func resolvedMovieGroupKey(_ key: String) -> String {
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

    // MARK: - Enrichment read overlay

    /// The pending enrichment for a catalog id — the urgent fast-track path when a
    /// grid/detail opens an item. A logical movie enriches its REPRESENTATIVE file
    /// (where movies() reads art); a series enriches its `series:<key>` row.
    func pendingEnrichment(forItemID id: String, version: Int) -> PendingEnrichment? {
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
            if enrichmentRepo.hasUsableEnrichment(itemID: itemID, version: version) { return nil }
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
            if enrichmentRepo.hasUsableEnrichment(itemID: itemID, version: version) { return nil }
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
                      ShareCatalogReadProjection.metadataValueMatches(
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
    func enrichmentRow(itemID: String) -> EnrichmentRecord? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url, title
        FROM enrichment WHERE item_id=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let record = ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 0) else { return nil }
        return hydratedEnrichmentRecords([itemID: record])[itemID]
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
                  let record = ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 1) else {
                continue
            }
            records[itemID] = record
        }
        sqlite3_finalize(stmt)
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(keyed.map { item, itemID in
            guard let itemID, let record = hydrated[itemID] else { return item }
            return ShareCatalogReadProjection.applyEnrichment(item, record)
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
            return ShareCatalogReadProjection.applyLocalMetadata(item, fields)
        }
    }

    /// Cheap, cached "does this catalog have ANY local metadata at all" check —
    /// see `LocalMetadataPresence`.
    private func hasAnyLocalMetadata() -> Bool {
        if let cached = localMetadataPresence.cached { return cached }
        guard db != nil else { return false }
        var found = false
        query("SELECT 1 FROM metadata_values WHERE source IN ('localNFO','filename') LIMIT 1;") { _ in found = true }
        localMetadataPresence.cached = found
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

    private func localMetadataRows(itemIDs: [String]) -> [String: [MetadataField: ShareCatalogReadProjection.LocalFieldRow]] {
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
        var out: [String: [MetadataField: ShareCatalogReadProjection.LocalFieldRow]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let itemID = columnText(stmt, 0),
                  let fieldRaw = columnText(stmt, 1),
                  let sourceRaw = columnText(stmt, 2),
                  let valueJSON = columnText(stmt, 3) else { continue }
            let field = MetadataField(rawValue: fieldRaw)
            var perItem = out[itemID] ?? [:]
            guard perItem[field] == nil else { continue } // First row per field wins (localNFO ordered first).
            perItem[field] = ShareCatalogReadProjection.LocalFieldRow(source: MetadataSource(rawValue: sourceRaw), valueJSON: valueJSON)
            out[itemID] = perItem
        }
        return out
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

    // MARK: - Assets-count query intents

    private func count(where clause: String?) -> Int {
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM assets" + (clause.map { " WHERE \($0)" } ?? "") + ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func distinctSeriesCount(library: CatalogLibrary) -> Int {
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT series_key) FROM assets WHERE library=? AND kind='episode' AND series_key IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, library.rawValue)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Small SQLite helpers
    //
    // Thin forwarders onto the actor-confined `CatalogConnection`, mirroring the
    // store's own primitive wrappers so the moved read-path bodies stay verbatim.

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        connection.query(sql, bind: bind, row: row)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        CatalogConnection.bindText(stmt, idx, value)
    }
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        CatalogConnection.columnText(stmt, idx)
    }
    private func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double {
        CatalogConnection.columnDouble(stmt, idx)
    }
    private func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        CatalogConnection.columnOptInt(stmt, idx)
    }
}
