import Foundation
import SQLite3
import CoreModels

/// Synchronous, transaction-free sidecar-inventory / value-cache / processing-state
/// SQL mechanics for one share catalog, running over the store-owned, actor-confined
/// `CatalogConnection`. It owns the *leaf* local-metadata persistence operations —
/// the `local_metadata_files` status/attempt columns and the
/// `local_metadata_file_values` parsed-field cache — that depend only on the
/// connection (plus module-level pure policies and the `PendingLocalMetadataFile`
/// DTO), never on `ShareCatalogStore` lifecycle state.
///
/// It holds no `BEGIN`/`COMMIT`: `ShareCatalogStore` remains the sole transaction
/// coordinator. Single-row writes here auto-commit through the open connection; the
/// one multi-statement replace (`replaceSidecarValueCache`) is transaction-free and
/// the store facade wraps it in one `BEGIN IMMEDIATE`/`COMMIT`.
///
/// Association resolution / candidate discovery / winner materialization stay in the
/// store for now: they read store lifecycle state (`normalizedMetadataReady`,
/// `hasAnyLocalMetadataCache`) and the shared movie-group asset read helpers, and
/// they write the shared `metadata_values` projection (an enrichment-domain table).
/// Those move under the post-B16 read-composition review (B17) rather than being
/// split here.
struct LocalMetadataRepository {
    let connection: CatalogConnection
    private var db: OpaquePointer? { connection.db }

    /// The projection columns for `materializePendingLocalMetadataFile`, shared by
    /// every pending/candidate/reassociation `SELECT` over `local_metadata_files`.
    static let pendingLocalMetadataFileColumns =
        "rel_path, parent_dir, kind, size, associated_video_rel_path, associated_item_id, fingerprint, scan_generation_bound, status, local_attempts"

    /// Row → `PendingLocalMetadataFile` mapper for a `pendingLocalMetadataFileColumns`
    /// row order. Pure decode; no lifecycle state.
    func materializePendingLocalMetadataFile(_ stmt: OpaquePointer?) -> PendingLocalMetadataFile? {
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

    /// The next bounded slice of pending sidecars for the scheduled background
    /// pass, oldest-scanned first.
    func pendingLocalMetadataFiles(limit: Int, maxAttempts: Int) -> [PendingLocalMetadataFile] {
        guard db != nil, limit > 0 else { return [] }
        var out: [PendingLocalMetadataFile] = []
        query("""
        SELECT \(Self.pendingLocalMetadataFileColumns) FROM local_metadata_files
        WHERE status='pending' AND local_attempts < ?
        ORDER BY last_scan, rel_path LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(maxAttempts))
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            if let file = self.materializePendingLocalMetadataFile(stmt) { out.append(file) }
        }
        return out
    }

    func sidecarStatus(relPath: String) -> String? {
        var status: String?
        query("SELECT status FROM local_metadata_files WHERE rel_path=?;",
              bind: { self.bindText($0, 1, relPath) }) { stmt in status = self.columnText(stmt, 0) }
        return status
    }

    /// The cached parsed field values for one sidecar (`nil` when never cached).
    func sidecarValueCache(relPath: String) -> [MetadataField: String] {
        guard db != nil else { return [:] }
        var out: [MetadataField: String] = [:]
        query("SELECT field, value_json FROM local_metadata_file_values WHERE rel_path=?;",
              bind: { self.bindText($0, 1, relPath) }) { stmt in
            guard let field = self.columnText(stmt, 0), let json = self.columnText(stmt, 1) else { return }
            out[MetadataField(rawValue: field)] = json
        }
        return out
    }

    /// Transaction-free core of the store's `writeSidecarValueCache`: replace one
    /// sidecar's entire `local_metadata_file_values` row set (delete + insert). The
    /// store facade wraps this in one `BEGIN IMMEDIATE`/`COMMIT`.
    func replaceSidecarValueCache(relPath: String, fields: [MetadataField: String]) -> Bool {
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
        return ok
    }

    @discardableResult
    func clearSidecarValueCache(relPath: String) -> Bool {
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
        parserVersion: Int = ShareNFOParser.parserVersion,
        now: Date = Date()
    ) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        UPDATE local_metadata_files SET
          status=?, processed_fingerprint=?, associated_item_id=?, parser_version=?,
          local_attempts=0, updated_at=?
        WHERE rel_path=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, status)
        bindOptText(stmt, 2, fingerprint)
        bindOptText(stmt, 3, associatedItemID)
        sqlite3_bind_int64(stmt, 4, Int64(parserVersion))
        sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
        bindText(stmt, 6, relPath)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Reread already-indexed NFOs exactly once after a parser-rule upgrade: mark
    /// every terminally-processed sidecar whose stored `parser_version` predates the
    /// current `ShareNFOParser.parserVersion` (or was never stamped) back to
    /// `pending`, so the local enricher reparses it under the corrected rules and
    /// restamps the new version. Idempotent — a row already at the current version,
    /// or one still `pending` (e.g. freshly inventoried this scan), is untouched, so
    /// the reread happens once, not on every scan. Touches no external/local-version
    /// state and forces no resolver call.
    @discardableResult
    func markSidecarsPendingForParserUpgrade(to version: Int = ShareNFOParser.parserVersion) -> Int {
        guard db != nil else { return 0 }
        guard exec("""
            UPDATE local_metadata_files
            SET status='pending', local_attempts=0, processed_fingerprint=NULL
            WHERE status <> 'pending' AND (parser_version IS NULL OR parser_version < \(version));
            """) else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Record a TRANSIENT transport failure: stays `pending`, bumps the bounded
    /// retry counter, never fabricates a successful local version.
    @discardableResult
    func markSidecarTransientFailure(relPath: String) -> Bool {
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
        guard db != nil else { return }
        _ = exec("UPDATE local_metadata_files SET local_attempts=0 WHERE status='pending';")
    }

    // MARK: - Connection primitive wrappers (mirror the store's, keeping moved bodies verbatim)

    private func exec(_ sql: String) -> Bool { connection.exec(sql) }
    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        connection.query(sql, bind: bind, row: row)
    }
    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        CatalogConnection.bindText(stmt, idx, value)
    }
    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        CatalogConnection.bindOptText(stmt, idx, value)
    }
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        CatalogConnection.columnText(stmt, idx)
    }
}
