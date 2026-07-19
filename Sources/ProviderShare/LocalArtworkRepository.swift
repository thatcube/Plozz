import Foundation
import SQLite3
import CoreModels

/// Leaf persistence for listing-only local-artwork inventory and its deterministic
/// associations. The store remains the transaction/lifecycle owner.
struct LocalArtworkRepository {
    let connection: CatalogConnection
    private var db: OpaquePointer? { connection.db }

    @discardableResult
    func upsert(_ artwork: [LocalArtworkCandidate], scanID: Int64, now: Date) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO local_artwork_files(
          rel_path,parent_dir,basename,extension,name_stem,name_role,explicit_media_stem,
          numbered_alternative,language,season,is_specials,folder_kind,size,modified_at,
          stable_file_id,strong_etag,change_token,fingerprint,scan_generation_bound,last_scan,
          probe_status,probe_attempts,updated_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',0,?)
        ON CONFLICT(rel_path) DO UPDATE SET
          parent_dir=excluded.parent_dir,basename=excluded.basename,extension=excluded.extension,
          name_stem=excluded.name_stem,name_role=excluded.name_role,
          explicit_media_stem=excluded.explicit_media_stem,numbered_alternative=excluded.numbered_alternative,
          language=excluded.language,season=excluded.season,is_specials=excluded.is_specials,
          folder_kind=excluded.folder_kind,size=excluded.size,modified_at=excluded.modified_at,
          stable_file_id=excluded.stable_file_id,strong_etag=excluded.strong_etag,
          change_token=excluded.change_token,fingerprint=excluded.fingerprint,
          scan_generation_bound=excluded.scan_generation_bound,last_scan=excluded.last_scan,
          probe_status=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                              OR excluded.scan_generation_bound=1 THEN 'pending'
                            ELSE local_artwork_files.probe_status END,
          processed_fingerprint=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                                       OR excluded.scan_generation_bound=1 THEN NULL
                                     ELSE local_artwork_files.processed_fingerprint END,
          probe_attempts=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                                OR excluded.scan_generation_bound=1 THEN 0
                              ELSE local_artwork_files.probe_attempts END,
          width=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                       OR excluded.scan_generation_bound=1 THEN NULL ELSE local_artwork_files.width END,
          height=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                        OR excluded.scan_generation_bound=1 THEN NULL ELSE local_artwork_files.height END,
          content_type=CASE WHEN local_artwork_files.fingerprint IS NOT excluded.fingerprint
                              OR excluded.scan_generation_bound=1 THEN NULL ELSE local_artwork_files.content_type END,
          updated_at=excluded.updated_at;
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for candidate in artwork {
            let fingerprint = ShareSidecarFingerprintPolicy.evaluate(
                strongETag: candidate.strongETag, changeToken: candidate.changeToken,
                stableFileID: candidate.stableFileID, modifiedAt: candidate.modifiedAt, size: candidate.size
            )
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, candidate.relPath)
            bindText(stmt, 2, candidate.parentDir)
            bindText(stmt, 3, candidate.basename)
            bindText(stmt, 4, (candidate.basename as NSString).pathExtension.lowercased())
            bindText(stmt, 5, candidate.facts.stem)
            bindOptText(stmt, 6, candidate.facts.role?.rawValue)
            bindOptText(stmt, 7, candidate.facts.explicitMediaStem)
            bindOptInt(stmt, 8, candidate.facts.numberedAlternative)
            bindOptText(stmt, 9, candidate.facts.language)
            bindOptInt(stmt, 10, candidate.facts.season)
            sqlite3_bind_int64(stmt, 11, candidate.facts.isSpecialsSeason ? 1 : 0)
            bindText(stmt, 12, candidate.isBackdropFolder ? "backdropFolder" : "directory")
            sqlite3_bind_int64(stmt, 13, candidate.size)
            sqlite3_bind_double(stmt, 14, candidate.modifiedAt.timeIntervalSince1970)
            bindOptText(stmt, 15, candidate.stableFileID)
            bindOptText(stmt, 16, candidate.strongETag)
            bindOptText(stmt, 17, candidate.changeToken)
            bindText(stmt, 18, fingerprint.fingerprint)
            sqlite3_bind_int64(stmt, 19, fingerprint.scanGenerationBound ? 1 : 0)
            sqlite3_bind_int64(stmt, 20, scanID)
            sqlite3_bind_double(stmt, 21, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    func staleAssociatedItemIDs(scanID: Int64) -> Set<String> {
        var ids = Set<String>()
        connection.query("""
        SELECT DISTINCT a.item_id FROM local_artwork_associations a
        JOIN local_artwork_files f ON f.rel_path=a.artwork_rel_path
        WHERE f.last_scan<>?;
        """, bind: { sqlite3_bind_int64($0, 1, scanID) }) {
            if let id = CatalogConnection.columnText($0, 0) { ids.insert(id) }
        }
        return ids
    }

    func pendingArtworkFiles(limit: Int, maxAttempts: Int) -> [PendingLocalArtworkFile] {
        guard limit > 0 else { return [] }
        var files: [PendingLocalArtworkFile] = []
        connection.query("""
        SELECT rel_path,size,modified_at,stable_file_id,strong_etag,change_token,fingerprint,probe_attempts
        FROM local_artwork_files
        WHERE probe_status='pending' AND probe_attempts<?
        ORDER BY last_scan,rel_path
        LIMIT ?;
        """, bind: {
            sqlite3_bind_int64($0, 1, Int64(maxAttempts))
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) {
            guard let path = CatalogConnection.columnText($0, 0),
                  let fingerprint = CatalogConnection.columnText($0, 6) else { return }
            files.append(.init(
                relPath: path,
                size: sqlite3_column_int64($0, 1),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double($0, 2)),
                stableFileID: CatalogConnection.columnText($0, 3),
                strongETag: CatalogConnection.columnText($0, 4),
                changeToken: CatalogConnection.columnText($0, 5),
                fingerprint: fingerprint,
                attempts: Int(sqlite3_column_int64($0, 7))
            ))
        }
        return files
    }

    @discardableResult
    func resetTransientProbeFailures() -> Bool {
        connection.exec("""
        UPDATE local_artwork_files
        SET probe_status='pending', probe_attempts=0, processed_fingerprint=NULL,
            updated_at=strftime('%s','now')
        WHERE probe_status='transientExhausted';
        """)
    }

    @discardableResult
    func updateProbe(
        relPath: String,
        fingerprint: String,
        status: String,
        probeVersion: Int?,
        width: Int?,
        height: Int?,
        contentType: String?,
        incrementAttempts: Bool,
        now: Date
    ) -> Bool {
        connection.runUpdate("""
        UPDATE local_artwork_files
        SET probe_status=?, probe_version=?, processed_fingerprint=fingerprint,
            width=?, height=?, content_type=?,
            probe_attempts=probe_attempts + ?,
            updated_at=?
        WHERE rel_path=? AND fingerprint=?;
        """, bind: {
            bindText($0, 1, status)
            bindOptInt($0, 2, probeVersion)
            bindOptInt($0, 3, width)
            bindOptInt($0, 4, height)
            bindOptText($0, 5, contentType)
            sqlite3_bind_int64($0, 6, incrementAttempts ? 1 : 0)
            sqlite3_bind_double($0, 7, now.timeIntervalSince1970)
            bindText($0, 8, relPath)
            bindText($0, 9, fingerprint)
        })
    }

    @discardableResult
    func deleteStale(inScan scanID: Int64) -> Bool {
        guard connection.runUpdate("DELETE FROM local_artwork_files WHERE last_scan<>?;", bind: {
            sqlite3_bind_int64($0, 1, scanID)
        }) else { return false }
        return connection.exec("""
        DELETE FROM local_artwork_associations
        WHERE NOT EXISTS(SELECT 1 FROM local_artwork_files f WHERE f.rel_path=artwork_rel_path);
        """)
    }

    @discardableResult
    func replaceAssociations(forArtworkPaths paths: [String], values: [ShareArtworkAssociation]) -> Bool {
        for path in Set(paths) {
            guard connection.runUpdate("DELETE FROM local_artwork_associations WHERE artwork_rel_path=?;", bind: {
                bindText($0, 1, path)
            }) else { return false }
        }
        return insertAssociations(values)
    }

    @discardableResult
    func replaceAllAssociations(_ values: [ShareArtworkAssociation]) -> Bool {
        guard connection.exec("DELETE FROM local_artwork_associations;") else { return false }
        return insertAssociations(values)
    }

    private func insertAssociations(_ values: [ShareArtworkAssociation]) -> Bool {
        guard !values.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO local_artwork_associations(item_id,placement,artwork_rel_path,rank,selected_order)
        VALUES(?,?,?,?,?);
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (order, value) in values.enumerated() {
            sqlite3_reset(stmt)
            bindText(stmt, 1, value.itemID)
            bindText(stmt, 2, value.placement.rawValue)
            bindText(stmt, 3, value.artworkRelPath)
            sqlite3_bind_int64(stmt, 4, Int64(value.rank))
            sqlite3_bind_int64(stmt, 5, Int64(order))
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    @discardableResult
    func replaceSelections(
        itemID: String,
        fields: [(field: String, valueJSON: String, sourceRevision: String)],
        now: Date
    ) -> Bool {
        guard connection.runUpdate("DELETE FROM metadata_values WHERE item_id=? AND source='localArtwork';", bind: {
            bindText($0, 1, itemID)
        }) else { return false }
        guard !fields.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO metadata_values(item_id,field,source,value_json,source_url,source_revision,refreshed_at,expires_at)
        VALUES(?,?,'localArtwork',?,NULL,?, ?,NULL);
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for field in fields {
            sqlite3_reset(stmt)
            bindText(stmt, 1, itemID)
            bindText(stmt, 2, field.field)
            bindText(stmt, 3, field.valueJSON)
            bindText(stmt, 4, field.sourceRevision)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        CatalogConnection.bindText(statement, index, value)
    }
    private func bindOptText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        CatalogConnection.bindOptText(statement, index, value)
    }
    private func bindOptInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        CatalogConnection.bindOptInt(statement, index, value)
    }
}
