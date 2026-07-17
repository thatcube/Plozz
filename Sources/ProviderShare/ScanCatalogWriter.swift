import Foundation
import SQLite3
import CoreModels

/// Transaction-bound, synchronous scan / movie-grouping SQL mechanics for one share
/// catalog. It runs through the store-owned, actor-confined `CatalogConnection`
/// inside the store's current transaction (notably the clean-scan `finalizeCleanScan`
/// BEGIN/COMMIT) and never owns a second connection, actor, or long-lived state.
///
/// Why only the *synchronous* scan work lives here: the single SQLite connection is
/// serialized exclusively by the `ShareCatalogStore` actor. The generation-gated,
/// chunked *async* writers (`upsert`, `rebuildMovieGroups`, `persistMovieAliases`)
/// release the actor at `await Task.yield()`, so they must remain actor-isolated in
/// the store to keep single-connection serialization; moving them into a
/// non-isolated value type would let a resumed write touch the connection
/// concurrently with an actor-scheduled read. This type therefore owns the pure
/// movie-clustering compute and the synchronous finalize step mechanics the store's
/// `finalizeCleanScan` coordinates, keeping those SQL bodies out of the store while
/// the actor keeps the serialization boundary.
struct ScanCatalogWriter {
    let connection: CatalogConnection
    private var db: OpaquePointer? { connection.db }

    struct MovieGroupingRow: Sendable {
        var relPath: String
        var movieKey: String
        var titleKey: String
        var year: Int?
        var existingGroup: String?
    }
    struct MovieGroupAssignment: Sendable {
        var relPath: String
        var group: String
    }
    struct MovieAlias: Sendable {
        var id: String
        var group: String
    }
    struct MovieGroupingPlan: Sendable {
        var assignments: [MovieGroupAssignment]
        var aliases: [MovieAlias]
    }

    /// Pure movie clustering: groups movie rows by normalized title, splits into
    /// year-adjacency clusters, folds year-less rows in, and picks each cluster's
    /// canonical group (an existing group if any, else the highest-year/movieKey
    /// fallback). Returns only CHANGED assignments plus the full alias set. No
    /// SQLite/actor state — shared verbatim by the async `rebuildMovieGroups` and
    /// the synchronous in-transaction clean-scan regroup.
    static func movieGroupingPlan(rows: [MovieGroupingRow]) -> MovieGroupingPlan {
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
    }

    /// `DELETE FROM <table> WHERE last_scan <> scanID`, bound. `table` is a
    /// compile-time literal at both call sites (no injection surface).
    func deleteWhereStale(table: String, scanID: Int64) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE last_scan <> ?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, scanID)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// The `associated_item_id`s of sidecars that this clean scan is about to prune
    /// (their `last_scan` no longer matches). Captured before the P4 delete so P7
    /// rematerializes each such item's winner from its surviving sidecars — the
    /// item whose winning sidecar vanished must lose the deleted value even when no
    /// surviving sidecar's association changed. Plain SELECT: no bound variable list.
    func staleSidecarAssociatedItemIDs(scanID: Int64) -> Set<String> {
        var ids = Set<String>()
        connection.query("SELECT associated_item_id FROM local_metadata_files WHERE last_scan <> ? AND associated_item_id IS NOT NULL;",
              bind: { sqlite3_bind_int64($0, 1, scanID) }) { stmt in
            if let itemID = CatalogConnection.columnText(stmt, 0) { ids.insert(itemID) }
        }
        return ids
    }

    /// P0 helper: the two alias-capture INSERTs of `preserveMovieAliasesBeforePrune`
    /// without their own transaction, so they join the clean-scan transaction.
    func preserveMovieAliasesInTransaction() -> Bool {
        guard connection.exec("""
            INSERT INTO movie_alias(alias_id, group_key)
            SELECT movie_key, COALESCE(movie_group_key, movie_key)
            FROM assets
            WHERE library='movies' AND kind='movie' AND movie_key IS NOT NULL
            ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
            """) else { return false }
        return connection.exec("""
            INSERT INTO movie_alias(alias_id, group_key)
            SELECT 'f:' || rel_path, COALESCE(movie_group_key, movie_key)
            FROM assets
            WHERE library='movies' AND kind='movie' AND movie_key IS NOT NULL
            ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
            """)
    }

    /// Synchronous, transaction-bound movie regroup: reads surviving movie rows,
    /// runs the same pure clustering as the async `rebuildMovieGroups`, then applies
    /// only changed group assignments plus the alias upserts inline (no nested
    /// transaction, no off-actor hop, no yield — the clean-scan transaction owns the
    /// serialization boundary). Behavior-identical result to `rebuildMovieGroups`
    /// over the same surviving asset set.
    func regroupMoviesInTransaction() -> Bool {
        var rows: [MovieGroupingRow] = []
        connection.query("""
        SELECT rel_path, movie_key, movie_title_key, year, movie_group_key
        FROM assets
        WHERE library='movies' AND kind='movie'
          AND movie_key IS NOT NULL AND movie_title_key IS NOT NULL;
        """) { stmt in
            guard let relPath = CatalogConnection.columnText(stmt, 0),
                  let movieKey = CatalogConnection.columnText(stmt, 1),
                  let titleKey = CatalogConnection.columnText(stmt, 2) else { return }
            rows.append(MovieGroupingRow(
                relPath: relPath, movieKey: movieKey, titleKey: titleKey,
                year: CatalogConnection.columnOptInt(stmt, 3), existingGroup: CatalogConnection.columnText(stmt, 4)
            ))
        }
        let plan = Self.movieGroupingPlan(rows: rows)
        if !plan.aliases.isEmpty {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            INSERT INTO movie_alias(alias_id, group_key) VALUES(?,?)
            ON CONFLICT(alias_id) DO UPDATE SET group_key=excluded.group_key;
            """, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            for alias in plan.aliases {
                sqlite3_reset(stmt)
                CatalogConnection.bindText(stmt, 1, alias.id)
                CatalogConnection.bindText(stmt, 2, alias.group)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            }
        }
        if !plan.assignments.isEmpty {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE assets SET movie_group_key=? WHERE rel_path=?;", -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            for assignment in plan.assignments {
                sqlite3_reset(stmt)
                CatalogConnection.bindText(stmt, 1, assignment.group)
                CatalogConnection.bindText(stmt, 2, assignment.relPath)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            }
        }
        return true
    }

    /// P5 helper: drop movie aliases whose group key backs no surviving movie, and
    /// series merges whose canonical AND alias keys both back no surviving series.
    /// Aliases/merges still needed by a surviving version/group are preserved.
    func cleanDeadAliasesInTransaction() -> Bool {
        guard connection.exec("""
            DELETE FROM movie_alias
            WHERE group_key NOT IN (
              SELECT COALESCE(movie_group_key, movie_key) FROM assets
              WHERE library='movies' AND kind='movie' AND movie_key IS NOT NULL
            );
            """) else { return false }
        return connection.exec("""
            DELETE FROM series_merge
            WHERE canonical_key NOT IN (SELECT series_key FROM assets WHERE series_key IS NOT NULL)
              AND alias_key NOT IN (SELECT series_key FROM assets WHERE series_key IS NOT NULL);
            """)
    }
}
