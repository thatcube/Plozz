import Foundation
import SQLite3
import CoreModels

/// Synchronous, transaction-free external/local enrichment persistence SQL mechanics
/// for one share catalog, running over the store-owned, actor-confined
/// `CatalogConnection`. It owns the *leaf* enrichment-domain persistence — writes and
/// reads over `enrichment` / `metadata_values` / `metadata_enrichment_state`, the
/// legacy-metadata migration, the scan-time pending-enrichment backlog queries, and
/// the explicit/local provider-id reads — that depend only on the connection (plus
/// module-level pure types: `EnrichmentRecord`, `PendingEnrichment`, `ShareCatalogID`,
/// `ShareLocalMetadataFieldCandidate`, and `CatalogJSON`), never on `ShareCatalogStore`
/// lifecycle state.
///
/// It holds no `BEGIN`/`COMMIT`: `ShareCatalogStore` remains the sole transaction
/// coordinator. Single-statement writes here auto-commit through the open connection;
/// the multi-statement writes (`writeMetadataValues`, `replaceLocalNFOMetadataValues`)
/// are transaction-free and their store callers own the ambient transaction
/// (`saveEnrichment`'s `BEGIN IMMEDIATE`, `finalizeCleanScan`, or
/// `replaceLocalNFOMetadata`'s wrapper). `deleteOrphanMetadataInTransaction` likewise
/// assumes the store's clean-scan transaction.
///
/// Read-*composition* that overlays enrichment onto `MediaItem` (`withEnrichment`,
/// `enrichmentRow`/`hydratedEnrichmentRecords`, `pendingEnrichment(forItemID:)`) and
/// the lifecycle-guarded local winner *materialization/repair* orchestration stay in
/// the store: they read store lifecycle state (`normalizedMetadataReady`,
/// `hasAnyLocalMetadataCache`) and the shared movie-group asset read helpers. Those
/// move under the post-B16 read-composition review (B17) rather than being split here.
struct EnrichmentRepository {
    let connection: CatalogConnection
    private var db: OpaquePointer? { connection.db }

    /// How many enrichment passes a miss is retried before it's settled as a genuine
    /// miss (bounded, not retried forever). Gives a transient rate-limit/timeout a
    /// few chances across scans to recover before the item is left blank.
    static let maxEnrichAttempts = 3
    /// Sentinel-free retry model: an unusable (empty) enrichment row is stored at
    /// the current `version` like any other, but this predicate (over a
    /// `LEFT JOIN enrichment e`) keeps it *pending* — retried up to
    /// `maxEnrichAttempts` — until it either resolves to something usable or is
    /// settled as a genuine miss. Matches a row with no ids, overview, or artwork.
    static let unusableEnrichmentPredicate =
        "e.provider_ids_json IS NULL AND e.overview IS NULL AND e.poster_url IS NULL "
        + "AND e.backdrop_url IS NULL AND e.logo_url IS NULL"

    // MARK: - External enrichment writes

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

    func writeMetadataValues(
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
            // isolation invariant — Step 3). Local writes go through
            // `replaceLocalNFOMetadata`/`repairFilenameProviderIDs`, each scoped
            // to its own source the mirror-opposite way.
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM metadata_values WHERE item_id=? AND source NOT IN ('localNFO','filename','localArtwork');",
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

    func writeEnrichmentState(
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

    /// Merge a freshly-resolved record onto the existing one: prefer a new non-empty
    /// value for each field, keep the existing otherwise, and UNION provider ids
    /// (so a sparse pass can never drop ids another pass found).
    static func merged(existing: EnrichmentRecord?, new: EnrichmentRecord) -> EnrichmentRecord {
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
    func enrichmentVersionAndAttempts(itemID: String) -> (version: Int, attempts: Int)? {
        guard db != nil else { return nil }
        var out: (Int, Int)?
        query("SELECT enrich_version, attempts FROM enrichment WHERE item_id=?;", bind: { self.bindText($0, 1, itemID) }) { stmt in
            out = (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return out
    }

    /// Whether `itemID` already has a **usable** enrichment row (any id / overview /
    /// artwork) at `version`. An unusable miss row does NOT count — so the fast-track
    /// path still re-attempts an item a user opens even after background retries
    /// settled it as a miss.
    func hasUsableEnrichment(itemID: String, version: Int) -> Bool {
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

    // MARK: - Local enrichment state (independent of external state)

    /// Local scheduling state — read/written ONLY by the local worker, entirely
    /// independent of `external_version`/`external_attempts` (see
    /// `writeEnrichmentState` for the external side). A local write NEVER touches
    /// the external columns, so it can't make an already-current external state
    /// pending, and vice versa.
    @discardableResult
    func writeLocalEnrichmentState(itemID: String, version: Int, attempts: Int) -> Bool {
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
        guard db != nil else { return nil }
        var out: (Int, Int)?
        query("SELECT local_version, local_attempts FROM metadata_enrichment_state WHERE item_id=?;",
              bind: { self.bindText($0, 1, itemID) }) { stmt in
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
            out = (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return out
    }

    /// The delete+insert core of `replaceLocalNFOMetadata` — replaces the whole
    /// `localNFO` lane for one item. Transaction-free: the store caller owns the
    /// ambient transaction (`replaceLocalNFOMetadata`'s `BEGIN IMMEDIATE` or the
    /// clean-scan transaction) and the `hasAnyLocalMetadataCache` invalidation.
    /// Returns false without committing on any SQLite failure; the caller owns rollback.
    @discardableResult
    func replaceLocalNFOMetadataValues(
        itemID: String,
        candidates: [ShareLocalMetadataFieldCandidate],
        now: Date = Date()
    ) -> Bool {
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
        return ok
    }

    // MARK: - Provider ids (explicit path + persisted local)

    /// Persisted explicit filename/folder provider ids for an asset (populated by
    /// the scanner from pure path parsing — see `CatalogAsset.explicitProviderIDs`).
    func explicitProviderIDs(relPath: String) -> [String: String] {
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

    // MARK: - Pending-enrichment backlog queries

    /// Logical items (movies + series) with no enrichment row at `version` yet,
    /// oldest-discovered first so a fresh library fills in a sensible order.
    func pendingEnrichment(
        version: Int,
        limit: Int,
        passStartedAt: Date? = nil
    ) -> [PendingEnrichment] {
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

    // MARK: - Orphan cleanup + legacy migration

    func deleteOrphanMetadataInTransaction() -> Bool {
        for table in ["enrichment", "metadata_values", "metadata_enrichment_state"] {
            let sql = """
            DELETE FROM \(table) WHERE
              (\(table).item_id LIKE 'f:%'
               AND NOT EXISTS(SELECT 1 FROM assets a WHERE a.rel_path = substr(\(table).item_id, 3)))
              OR (\(table).item_id LIKE 'series:%'
               AND NOT EXISTS(SELECT 1 FROM assets a WHERE a.series_key = substr(\(table).item_id, 8)));
            """
            guard exec(sql) else { return false }
        }
        return true
    }

    /// Backfill source-addressable rows from the flat projection without changing the
    /// projection or making any item newly eligible for enrichment.
    func migrateLegacyEnrichmentMetadata() -> Bool {
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

    func metadataMigrationComplete() -> Bool {
        var complete = false
        query("SELECT value FROM meta WHERE key='metadata_values_migrated_v1';") { stmt in
            complete = self.columnText(stmt, 0) == "1"
        }
        return complete
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
    private func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        CatalogConnection.columnOptInt(stmt, idx)
    }
    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        CatalogJSON.encode(value)
    }
    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        CatalogJSON.decode(type, json)
    }
}
