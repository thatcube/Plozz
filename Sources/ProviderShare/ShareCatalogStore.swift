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
    private let enrichmentSaveFailurePoint: EnrichmentSaveFailurePoint?
    /// The actor-confined SQLite handle owner. Never escapes this actor and is only
    /// ever touched under the store's isolation, preserving the single-connection,
    /// single-threaded invariant. See `CatalogConnection`.
    private let connection: CatalogConnection
    /// Bridge so the store's existing raw `sqlite3_*` call sites read the connection's
    /// handle unchanged; the connection owns its lifetime (open/close).
    private var db: OpaquePointer? { connection.db }
    /// Transaction-bound series reconciler over the same actor-confined connection.
    /// A cheap value type constructed on demand; it holds no state of its own and
    /// only runs while the store's actor is executing a catalog transaction.
    private var reconciler: ShareSeriesReconciler { ShareSeriesReconciler(connection: connection) }
    private var scanWriter: ScanCatalogWriter { ScanCatalogWriter(connection: connection) }
    private var localRepo: LocalMetadataRepository { LocalMetadataRepository(connection: connection) }
    private var artworkRepo: LocalArtworkRepository { LocalArtworkRepository(connection: connection) }
    private var enrichmentRepo: EnrichmentRepository { EnrichmentRepository(connection: connection) }
    /// Pure, transaction-free read-query composition over the same actor-confined
    /// connection. A cheap value type constructed on demand; it holds no state of its
    /// own, opens no transaction, and only runs while the store's actor is executing.
    /// `normalizedMetadataReady` is snapshotted by value (reads are serialized on this
    /// actor, so the snapshot equals the live value for one read) and the "has any
    /// local metadata" memo is shared through the store-owned `localMetadataPresence`
    /// box, which the store's write paths invalidate. The store's public read methods
    /// `ensureOpen()` before delegating here.
    private var readQueries: CatalogReadQueries {
        CatalogReadQueries(
            connection: connection,
            normalizedMetadataReady: normalizedMetadataReady,
            localMetadataPresence: localMetadataPresence
        )
    }
    private var normalizedMetadataReady = false
    /// Cached "does ANY local (NFO/filename) metadata_values row exist" check —
    /// avoids a real query on every read-path call (`withLocalOverlay`/grid sort
    /// join) for the common no-NFO catalog, where it must add negligible
    /// overhead over the existing no-NFO behavior. `nil` until first computed;
    /// flips true immediately on a successful local write, never flips back to
    /// false speculatively (a stale `true` after the last sidecar is removed just
    /// costs one harmless empty-result query, not a correctness issue). Shared with
    /// `CatalogReadQueries` (which lazily populates it) via a reference box.
    private let localMetadataPresence = LocalMetadataPresence()
    private var activeScanGeneration: UUID?
    private var pendingMergedSeriesLocalRepairs = Set<String>()
    /// Runtime-only credential-safe context used solely to materialize transport
    /// references. The SQLite inventory never stores credentials, endpoints, or URLs.
    private var artworkReferenceContext: (accountID: String, credentialRevision: CredentialRevision)?
    /// Persisted only as an opaque hash of account identity + credential revision.
    /// This avoids rematerializing every item after a process relaunch while never
    /// storing credentials or artwork paths in catalog metadata.
    private static let artworkReferenceContextMetaKey = "artwork_reference_context_v1"

    /// Bounded catalog writes keep the actor cooperative with Home/grid/search
    /// reads while a large share is scanning.
    private static let writeChunkSize = 200

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
        let fileURL = base.appendingPathComponent("share-catalog-\(Self.sanitize(accountKey)).sqlite")
        self.url = fileURL
        self.connection = CatalogConnection(url: fileURL)
        self.enrichmentSaveFailurePoint = enrichmentSaveFailurePoint
    }

    // MARK: - Open / schema

    /// Opens the connection and migrates schema (idempotent), then runs the one-time
    /// post-open local-projection repairs exactly once, on the transition where the
    /// schema was just committed ready. All raw SQLite mechanics — open, pragmas,
    /// transaction scope, and DDL — live in `CatalogConnection`; the legacy
    /// metadata-values migration (a store-owned data concern) runs inside that same
    /// transaction via the supplied closure at its original point.
    private func ensureOpen() {
        let becameReady = connection.ensureOpen(legacyMetadataMigration: { conn in
            guard !self.enrichmentRepo.metadataMigrationComplete() else { return true }
            guard self.enrichmentRepo.migrateLegacyEnrichmentMetadata(),
                  conn.exec("""
                      INSERT INTO meta(key, value) VALUES('metadata_values_migrated_v1', '1')
                      ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                      """)
            else { return false }
            return true
        })
        if becameReady {
            normalizedMetadataReady = true
            repairAllLocalMetadataProjections()
            repairFilenameProviderIDs()
        }
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
        let seriesAliases = reconciler.seriesMergeMap()

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
                bindOptText(stmt, 13, a.seriesKey.map { ShareSeriesReconciler.resolveAlias($0, in: seriesAliases) })
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
        reassociateArtwork(afterUpserting: assets)
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

        var rows: [ScanCatalogWriter.MovieGroupingRow] = []
        query("""
        SELECT rel_path, movie_key, movie_title_key, year, movie_group_key
        FROM assets
        WHERE library='movies' AND kind='movie'
          AND movie_key IS NOT NULL AND movie_title_key IS NOT NULL;
        """) { stmt in
            guard let relPath = self.columnText(stmt, 0),
                  let movieKey = self.columnText(stmt, 1),
                  let titleKey = self.columnText(stmt, 2) else { return }
            rows.append(ScanCatalogWriter.MovieGroupingRow(
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
        let plan: ScanCatalogWriter.MovieGroupingPlan = await Task.detached(priority: .utility) {
            ScanCatalogWriter.movieGroupingPlan(rows: rows)
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
        _ aliases: [ScanCatalogWriter.MovieAlias],
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

    /// Internal coordinator handoff. The public catalog reader contract stays frozen;
    /// this is available exactly where the account credential revision already exists.
    func configureArtworkReferenceContext(accountID: String, credentialRevision: CredentialRevision) {
        ensureOpen()
        guard db != nil else { return }
        artworkReferenceContext = (accountID, credentialRevision)
        let marker = opaqueArtworkRevision(
            accountID: accountID,
            path: Self.artworkReferenceContextMetaKey,
            fingerprint: credentialRevision.rawValue.uuidString
        )
        guard meta(Self.artworkReferenceContextMetaKey) != marker else { return }

        let itemIDs = allArtworkAssociatedItemIDs().sorted()
        guard exec("BEGIN IMMEDIATE;") else { return }
        for itemID in itemIDs {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        setMeta(Self.artworkReferenceContextMetaKey, marker)
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    // MARK: - Local artwork inventory (Step 4)

    /// Artwork transport failures get the same bounded retry posture as NFOs.
    /// Terminal header outcomes are settled against their exact fingerprint.
    static let maxArtworkProbeAttempts = 3

    func pendingArtworkProbes(limit: Int) -> [PendingLocalArtworkFile] {
        ensureOpen()
        return artworkRepo.pendingArtworkFiles(limit: limit, maxAttempts: Self.maxArtworkProbeAttempts)
    }

    func recordArtworkProbeTransientFailure(_ file: PendingLocalArtworkFile) {
        ensureOpen()
        guard db != nil else { return }
        let terminal = file.attempts + 1 >= Self.maxArtworkProbeAttempts
        if terminal {
            guard exec("BEGIN IMMEDIATE;") else { return }
        }
        let affected = terminal ? artworkAssociatedItemIDs(paths: [file.relPath]) : []
        guard artworkRepo.updateProbe(
            relPath: file.relPath,
            fingerprint: file.fingerprint,
            status: terminal ? "transientExhausted" : "pending",
            probeVersion: nil,
            width: nil,
            height: nil,
            contentType: nil,
            incrementAttempts: true,
            now: Date()
        ) else {
            if terminal { _ = exec("ROLLBACK;") }
            return
        }
        guard terminal else { return }
        for itemID in affected.sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    func resetArtworkProbeTransientFailures() {
        ensureOpen()
        guard db != nil, exec("BEGIN IMMEDIATE;") else { return }
        var affected = Set<String>()
        query("""
        SELECT DISTINCT a.item_id
        FROM local_artwork_associations a
        JOIN local_artwork_files f ON f.rel_path=a.artwork_rel_path
        WHERE f.probe_status='transientExhausted';
        """) { stmt in
            if let itemID = self.columnText(stmt, 0) { affected.insert(itemID) }
        }
        guard artworkRepo.resetTransientProbeFailures() else {
            _ = exec("ROLLBACK;")
            return
        }
        for itemID in affected.sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    /// Persist an inspected header only when the exact scanned fingerprint remains
    /// current, then rematerialize just its associated catalog items.
    func setArtworkProbeResult(
        _ file: PendingLocalArtworkFile,
        result: ShareArtworkHeaderInspection
    ) {
        ensureOpen()
        guard db != nil, exec("BEGIN IMMEDIATE;") else { return }
        let affected = artworkAssociatedItemIDs(paths: [file.relPath])
        let update: (status: String, version: Int?, width: Int?, height: Int?, type: String?)
        switch result {
        case .validated(let width, let height, let contentType):
            update = ("validated", ShareLocalArtworkProbeWorker.version, width, height, contentType)
        case .incomplete:
            update = ("unvalidated", ShareLocalArtworkProbeWorker.version, nil, nil, nil)
        case .empty:
            update = ("empty", ShareLocalArtworkProbeWorker.version, nil, nil, nil)
        case .unsupported:
            update = ("unsupported", ShareLocalArtworkProbeWorker.version, nil, nil, nil)
        case .malformed:
            update = ("malformed", ShareLocalArtworkProbeWorker.version, nil, nil, nil)
        case .tooLarge:
            update = ("rejected", ShareLocalArtworkProbeWorker.version, nil, nil, nil)
        }
        guard artworkRepo.updateProbe(
            relPath: file.relPath,
            fingerprint: file.fingerprint,
            status: update.status,
            probeVersion: update.version,
            width: update.width,
            height: update.height,
            contentType: update.type,
            incrementAttempts: false,
            now: Date()
        ) else {
            _ = exec("ROLLBACK;")
            return
        }
        for itemID in affected.sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    func upsertArtwork(
        _ artwork: [LocalArtworkCandidate],
        scanID: Int64,
        now: Date = Date(),
        scanGeneration: UUID? = nil
    ) async {
        ensureOpen()
        guard admits(scanGeneration), db != nil, !artwork.isEmpty,
              exec("BEGIN IMMEDIATE;") else { return }
        let priorItems = artworkAssociatedItemIDs(paths: artwork.map(\.relPath))
        guard artworkRepo.upsert(artwork, scanID: scanID, now: now),
              associateArtworkInTransaction(artwork) else {
            _ = exec("ROLLBACK;")
            return
        }
        let currentItems = artworkAssociatedItemIDs(paths: artwork.map(\.relPath))
        for itemID in priorItems.union(currentItems).sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    /// Clean scans rebuild only the local-artwork lane after pruning stale inventory.
    /// Partial scans never call this path, so they cannot delete or globally
    /// re-associate unseen artwork.
    private func finalizeArtworkInTransaction(scanID: Int64) -> Bool {
        let previous = allArtworkAssociatedItemIDs()
        guard artworkRepo.deleteStale(inScan: scanID) else { return false }
        let candidates = storedArtworkCandidates()
        let assets = artworkCatalogAssets()
        guard artworkRepo.replaceAllAssociations(
            candidates.flatMap {
                ShareArtworkAssociationPolicy.associations(candidate: $0, assets: assets)
            }
        ) else { return false }
        let current = artworkAssociatedItemIDs(paths: candidates.map(\.relPath))
        for itemID in previous.union(current).sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else { return false }
        }
        return true
    }

    private func associateArtworkInTransaction(_ artwork: [LocalArtworkCandidate]) -> Bool {
        let assets = artworkCatalogAssets()
        return artworkRepo.replaceAssociations(
            forArtworkPaths: artwork.map(\.relPath),
            values: artwork.flatMap {
                ShareArtworkAssociationPolicy.associations(candidate: $0, assets: assets)
            }
        )
    }

    private func reassociateArtwork(afterUpserting assets: [CatalogAsset]) {
        var directories = Set(assets.map { ($0.relPath as NSString).deletingLastPathComponent })
        directories.formUnion(assets.compactMap(\.metadataRoot))
        let directArtworkDirectories = directories.flatMap {
            $0.isEmpty
                ? ["", "backdrops", "extrafanart"]
                : [$0, "\($0)/backdrops", "\($0)/extrafanart"]
        }
        let candidates = storedArtworkCandidates(inDirectories: Set(directArtworkDirectories))
        guard !candidates.isEmpty, exec("BEGIN IMMEDIATE;") else { return }
        let prior = artworkAssociatedItemIDs(paths: candidates.map(\.relPath))
        guard associateArtworkInTransaction(candidates) else {
            _ = exec("ROLLBACK;")
            return
        }
        let current = artworkAssociatedItemIDs(paths: candidates.map(\.relPath))
        for itemID in prior.union(current).sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    private func reassociateAllArtworkInTransaction() -> Bool {
        let previous = allArtworkAssociatedItemIDs()
        let candidates = storedArtworkCandidates()
        let assets = artworkCatalogAssets()
        guard artworkRepo.replaceAllAssociations(
            candidates.flatMap {
                ShareArtworkAssociationPolicy.associations(candidate: $0, assets: assets)
            }
        ) else { return false }
        let current = artworkAssociatedItemIDs(paths: candidates.map(\.relPath))
        for itemID in previous.union(current).sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else { return false }
        }
        return true
    }

    private func artworkCatalogAssets() -> [ShareArtworkCatalogAsset] {
        struct Row {
            var relPath: String
            var kind: CatalogAssetKind
            var group: String?
            var seriesKey: String?
            var season: Int?
            var metadataRoot: String?
        }
        var rows: [Row] = []
        query("""
        SELECT rel_path, kind, COALESCE(movie_group_key,movie_key), series_key, season, metadata_root
        FROM assets;
        """) { stmt in
            guard let path = self.columnText(stmt, 0),
                  let kind = CatalogAssetKind(rawValue: self.columnText(stmt, 1) ?? "") else { return }
            rows.append(.init(relPath: path, kind: kind, group: self.columnText(stmt, 2),
                              seriesKey: self.columnText(stmt, 3), season: self.columnOptInt(stmt, 4),
                              metadataRoot: self.columnText(stmt, 5)))
        }
        let reps = Dictionary(grouping: rows.filter { $0.kind == .movie && $0.group != nil }, by: { $0.group! })
            .mapValues { $0.map(\.relPath).min()! }
        return rows.map {
            .init(
                relPath: $0.relPath, kind: $0.kind,
                movieOwnerID: $0.group.flatMap { reps[$0] }.map(ShareCatalogID.file),
                seriesKey: $0.seriesKey, season: $0.season, metadataRoot: $0.metadataRoot
            )
        }
    }

    private func storedArtworkCandidates(
        inDirectories directories: Set<String>? = nil
    ) -> [LocalArtworkCandidate] {
        var output: [LocalArtworkCandidate] = []
        var sql = """
        SELECT rel_path,parent_dir,basename,name_stem,name_role,explicit_media_stem,
               numbered_alternative,language,season,is_specials,folder_kind,size,modified_at,
               stable_file_id,strong_etag,change_token
        FROM local_artwork_files
        """
        let orderedDirectories = directories.map { Array($0).sorted() } ?? []
        if !orderedDirectories.isEmpty {
            sql += " WHERE parent_dir IN (\(Array(repeating: "?", count: orderedDirectories.count).joined(separator: ",")))"
        }
        sql += " ORDER BY rel_path;"
        query(sql, bind: { stmt in
            for (offset, directory) in orderedDirectories.enumerated() {
                self.bindText(stmt, Int32(offset + 1), directory)
            }
        }) { stmt in
            guard let relPath = self.columnText(stmt, 0),
                  let parentDir = self.columnText(stmt, 1),
                  let basename = self.columnText(stmt, 2),
                  let stem = self.columnText(stmt, 3) else { return }
            output.append(.init(
                relPath: relPath, parentDir: parentDir, basename: basename,
                facts: .init(
                    stem: stem, role: self.columnText(stmt, 4).flatMap(ShareArtworkRole.init(rawValue:)),
                    explicitMediaStem: self.columnText(stmt, 5),
                    numberedAlternative: self.columnOptInt(stmt, 6),
                    language: self.columnText(stmt, 7), season: self.columnOptInt(stmt, 8),
                    isSpecialsSeason: sqlite3_column_int64(stmt, 9) != 0
                ),
                size: sqlite3_column_int64(stmt, 11),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
                stableFileID: self.columnText(stmt, 13), strongETag: self.columnText(stmt, 14),
                changeToken: self.columnText(stmt, 15), isBackdropFolder: self.columnText(stmt, 10) == "backdropFolder"
            ))
        }
        return output
    }

    private func artworkAssociatedItemIDs(paths: [String]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        var result = Set<String>()
        query("SELECT DISTINCT item_id FROM local_artwork_associations WHERE artwork_rel_path IN (\(placeholders));",
              bind: { stmt in
            for (offset, path) in paths.enumerated() { self.bindText(stmt, Int32(offset + 1), path) }
        }) { stmt in
            if let id = self.columnText(stmt, 0) { result.insert(id) }
        }
        return result
    }

    private func allArtworkAssociatedItemIDs() -> Set<String> {
        var result = Set<String>()
        query("SELECT DISTINCT item_id FROM local_artwork_associations;") { stmt in
            if let id = self.columnText(stmt, 0) { result.insert(id) }
        }
        return result
    }

    func rejectArtworkReference(_ reference: NetworkArtworkReference) {
        ensureOpen()
        guard let context = artworkReferenceContext,
              context.accountID == reference.accountID,
              context.credentialRevision == reference.credentialRevision
        else { return }
        var fingerprint: String?
        var scanGenerationBound = false
        var lastScan: Int64 = 0
        query("""
        SELECT fingerprint,scan_generation_bound,last_scan
        FROM local_artwork_files WHERE rel_path=?;
        """, bind: { self.bindText($0, 1, reference.relativePath) }) { stmt in
            fingerprint = self.columnText(stmt, 0)
            scanGenerationBound = sqlite3_column_int64(stmt, 1) != 0
            lastScan = sqlite3_column_int64(stmt, 2)
        }
        guard let fingerprint,
              reference.sourceRevision == opaqueArtworkRevision(
                accountID: context.accountID,
                path: reference.relativePath,
                fingerprint: artworkSourceFingerprint(
                    fingerprint: fingerprint,
                    scanGenerationBound: scanGenerationBound,
                    lastScan: lastScan
                )
              ),
              exec("BEGIN IMMEDIATE;")
        else { return }
        let affected = artworkAssociatedItemIDs(paths: [reference.relativePath])
        guard connection.runUpdate("""
        UPDATE local_artwork_files
        SET probe_status='rejected',
            processed_fingerprint=fingerprint,
            probe_attempts=probe_attempts+1,
            updated_at=?
        WHERE rel_path=? AND fingerprint=?;
        """, bind: {
            sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
            self.bindText($0, 2, reference.relativePath)
            self.bindText($0, 3, fingerprint)
        }) else {
            _ = exec("ROLLBACK;")
            return
        }
        for itemID in affected.sorted() {
            guard materializeArtworkSelectionsInTransaction(itemID: itemID) else {
                _ = exec("ROLLBACK;")
                return
            }
        }
        guard exec("COMMIT;") else { _ = exec("ROLLBACK;"); return }
    }

    @discardableResult
    private func materializeArtworkSelections(itemID: String) -> Bool {
        guard exec("BEGIN IMMEDIATE;"),
              materializeArtworkSelectionsInTransaction(itemID: itemID),
              exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        return true
    }

    @discardableResult
    private func materializeArtworkSelectionsInTransaction(itemID: String) -> Bool {
        guard let context = artworkReferenceContext else {
            return artworkRepo.replaceSelections(itemID: itemID, fields: [], now: Date())
        }
        struct Row {
            var placement: ArtworkPlacement
            var path: String
            var size: Int64
            var modifiedAt: Date
            var stableID: String?
            var etag: String?
            var fingerprint: String
            var contentType: String?
            var width: Int?
            var height: Int?
            var rank: Int
            var scanGenerationBound: Bool
            var lastScan: Int64
        }
        var rows: [Row] = []
        query("""
        SELECT a.placement,f.rel_path,f.size,f.modified_at,f.stable_file_id,f.strong_etag,
               f.fingerprint,f.content_type,f.width,f.height,a.rank,
               f.scan_generation_bound,f.last_scan
        FROM local_artwork_associations a
        JOIN local_artwork_files f ON f.rel_path=a.artwork_rel_path
        WHERE a.item_id=? AND f.probe_status IN ('pending','unvalidated','validated')
          AND NOT (
            f.probe_status='validated'
            AND f.width > 3 * f.height
            AND a.placement IN ('homeHero','detailBackdrop')
          )
        ORDER BY a.placement,a.rank,f.rel_path;
        """, bind: { self.bindText($0, 1, itemID) }) { stmt in
            guard let placement = self.columnText(stmt, 0).map(ArtworkPlacement.init(rawValue:)),
                  let path = self.columnText(stmt, 1), let fingerprint = self.columnText(stmt, 6) else { return }
            rows.append(.init(
                placement: placement, path: path, size: sqlite3_column_int64(stmt, 2),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                stableID: self.columnText(stmt, 4), etag: self.columnText(stmt, 5),
                fingerprint: fingerprint, contentType: self.columnText(stmt, 7),
                width: self.columnOptInt(stmt, 8), height: self.columnOptInt(stmt, 9),
                rank: Int(sqlite3_column_int64(stmt, 10)),
                scanGenerationBound: sqlite3_column_int64(stmt, 11) != 0,
                lastScan: sqlite3_column_int64(stmt, 12)
            ))
        }
        let byPlacement = Dictionary(grouping: rows, by: \.placement)
        var detailOrder: [ShareArtworkRankedCandidate]?
        if let home = byPlacement[.homeHero], let detail = byPlacement[.detailBackdrop] {
            let homeRanked = ShareArtworkRankingPolicy.ordered(home.map {
                ShareArtworkRankedCandidate(relPath: $0.path, rank: $0.rank)
            }, placement: .homeHero)
            let detailRanked = ShareArtworkRankingPolicy.distinctDetail(
                home: homeRanked,
                detail: ShareArtworkRankingPolicy.ordered(detail.map {
                    ShareArtworkRankedCandidate(relPath: $0.path, rank: $0.rank)
                }, placement: .detailBackdrop)
            )
            detailOrder = detailRanked
        }
        let fields = byPlacement.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { placement -> (String, String, String)? in
            let ranked = ShareArtworkRankingPolicy.ordered(
                (byPlacement[placement] ?? []).map {
                    ShareArtworkRankedCandidate(relPath: $0.path, rank: $0.rank)
                },
                placement: placement
            )
            let ordered = placement == .detailBackdrop ? (detailOrder ?? ranked) : ranked
            let references = ordered.compactMap { ranked -> ArtworkReference? in
                guard let row = (byPlacement[placement] ?? []).first(where: { $0.path == ranked.relPath }),
                      let identity = artworkIdentity(
                        stableID: row.stableID, etag: row.etag, modifiedAt: row.modifiedAt
                      ),
                      let representation = try? RemoteFileRepresentation(
                        size: row.size, identity: identity, consistency: .changeDetecting
                      ),
                      let reference = try? NetworkArtworkReference(
                        accountID: context.accountID, credentialRevision: context.credentialRevision,
                        relativePath: row.path, representation: representation,
                        sourceRevision: opaqueArtworkRevision(
                            accountID: context.accountID,
                            path: row.path,
                            fingerprint: artworkSourceFingerprint(
                                fingerprint: row.fingerprint,
                                scanGenerationBound: row.scanGenerationBound,
                                lastScan: row.lastScan
                            )
                        ),
                        contentType: row.contentType,
                        dimensions: dimensions(width: row.width, height: row.height)
                      ) else { return nil }
                return .networkFile(reference)
            }
            guard !references.isEmpty,
                  let json = encodeJSON(ArtworkSelection(placement: placement, references: references)) else { return nil }
            let revisions = references.compactMap { reference -> String? in
                guard case .networkFile(let network) = reference else { return nil }
                return network.sourceRevision
            }.joined(separator: ",")
            return ("artwork.\(placement.rawValue)", json, opaqueArtworkRevision(
                accountID: context.accountID, path: itemID, fingerprint: revisions
            ))
        }
        return artworkRepo.replaceSelections(itemID: itemID, fields: fields, now: Date())
    }

    private func artworkSourceFingerprint(
        fingerprint: String,
        scanGenerationBound: Bool,
        lastScan: Int64
    ) -> String {
        scanGenerationBound ? "\(fingerprint)|scan:\(lastScan)" : fingerprint
    }

    private func artworkIdentity(stableID: String?, etag: String?, modifiedAt: Date) -> RemoteFileIdentity? {
        if let etag, let identity = try? RemoteFileIdentity(kind: .strongETag, value: etag) { return identity }
        if let stableID, let identity = try? RemoteFileIdentity(kind: .fileIdentifier, value: stableID) { return identity }
        return try? RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt)
    }

    private func dimensions(width: Int?, height: Int?) -> ArtworkDimensions? {
        guard let width, let height else { return nil }
        return try? ArtworkDimensions(width: width, height: height)
    }

    private func opaqueArtworkRevision(accountID: String, path: String, fingerprint: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(accountID)|\(path)|\(fingerprint)|artwork-v1".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "la-\(String(hash, radix: 16))"
    }

    // MARK: - Local NFO / explicit-id sidecar inventory (Step 3)

    /// Bounded retry cap for a sidecar stuck on a TRANSIENT transport failure —
    /// mirrors `maxEnrichAttempts`'s "bounded, never retried forever" posture.
    static let maxLocalAttempts = 3

    /// One sidecar row read back for the local metadata worker (either the
    /// scheduled slice's next batch, or the urgent opened-item lookup).
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

    // MARK: - Atomic clean-scan finalization (Batch 5)

    /// Finalize a CLEAN (no listing failure) full scan in ONE synchronous
    /// `BEGIN IMMEDIATE` transaction. Replaces the former sequence of independent
    /// single-statement/own-transaction passes (`preserveMovieAliasesBeforePrune`
    /// → `pruneNotSeen` → `pruneSidecarsNotSeen` → `rebuildMovieGroups` →
    /// `reconcileSidecarAssociations` → `materializeFilenameProviderIDs`). That
    /// sequence deleted assets without ever removing the `enrichment`/
    /// `metadata_values`/`metadata_enrichment_state` rows they left behind, so a
    /// later reuse of the same path or series key resurrected stale ids/artwork/
    /// completed state; it could also be interrupted between passes, leaving a
    /// half-pruned catalog. Every phase here commits atomically: after `COMMIT`
    /// every readable item already exposes the correct surviving local/filename/
    /// external fallback, and no orphan row can resurface. Partial/cancelled scans
    /// never call this. Transport-free and never yields the actor.
    ///
    /// `failurePoint` is test-only; forcing a failure after any phase must roll the
    /// whole transaction back so a reopen sees the complete old or complete
    /// corrected state, never a partial mutation.
    func finalizeCleanScan(
        inScan scanID: Int64,
        scanGeneration: UUID? = nil,
        failurePoint: CleanScanFailurePoint? = nil
    ) -> Bool {
        ensureOpen()
        guard admits(scanGeneration), db != nil, normalizedMetadataReady else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        func rollback() -> Bool { _ = exec("ROLLBACK;"); return false }

        // P0 — Preserve a soon-to-be-removed movie version's aliases (captured from
        // the pre-delete catalog) so its legacy file id still resolves to the
        // surviving logical group.
        guard scanWriter.preserveMovieAliasesInTransaction() else { return rollback() }

        // P1 — Drop assets no longer present on the share.
        guard scanWriter.deleteWhereStale(table: "assets", scanID: scanID),
              failurePoint != .afterAssetDelete else { return rollback() }

        // P2 — Recompute movie group keys on the surviving assets. Association
        // resolution below reads the group representative, so this must precede it.
        guard scanWriter.regroupMoviesInTransaction(),
              failurePoint != .afterMovieRegroup else { return rollback() }

        // P3 — Delete orphan enrichment/metadata rows for every item id whose
        // backing asset just vanished (derived live ids via NOT EXISTS).
        guard enrichmentRepo.deleteOrphanMetadataInTransaction(),
              failurePoint != .afterOrphanMetadataCleanup else { return rollback() }

        // P4 — Delete vanished sidecar inventory and any value-cache row whose
        // parent inventory row no longer exists (NOT EXISTS, never a bound IN list,
        // so it holds above the SQLite variable limit). Capture the item ids whose
        // sidecar is about to vanish FIRST: an item whose winning sidecar was
        // deleted must be rematerialized from its surviving sidecars in P7 even
        // when no surviving sidecar's association changed.
        let orphanedSidecarItemIDs = scanWriter.staleSidecarAssociatedItemIDs(scanID: scanID)
        guard scanWriter.deleteWhereStale(table: "local_metadata_files", scanID: scanID) else { return rollback() }
        guard exec("""
            DELETE FROM local_metadata_file_values
            WHERE NOT EXISTS(
              SELECT 1 FROM local_metadata_files f
              WHERE f.rel_path = local_metadata_file_values.rel_path
            );
            """), failurePoint != .afterSidecarCleanup else { return rollback() }

        // Local artwork is a separate source lane. Its inventory and associations
        // obey the same clean-only delete invariant, but it never touches external
        // enrichment rows or their retry state.
        guard finalizeArtworkInTransaction(scanID: scanID) else { return rollback() }

        // P5 — Clean only alias/reconciliation rows proven to have no live logical
        // asset; aliases still backing a surviving version/group are preserved.
        guard scanWriter.cleanDeadAliasesInTransaction(),
              failurePoint != .afterAliasCleanup else { return rollback() }

        // P6 — Recompute surviving sidecar associations from persisted assets.
        let association = recomputeSidecarAssociationsInTransaction()
        guard association.ok,
              failurePoint != .afterAssociationRecompute else { return rollback() }

        // P7 — Rematerialize local NFO winners for every affected item from the
        // surviving persisted per-sidecar value cache. Union of items whose
        // surviving association changed and items whose winning sidecar vanished.
        for itemID in association.affectedItemIDs.union(orphanedSidecarItemIDs).sorted() {
            guard materializeCachedLocalMetadataInTransaction(itemID: itemID) else { return rollback() }
        }
        guard failurePoint != .afterWinnerRematerialize else { return rollback() }

        // P8 — Rematerialize the flat filename/explicit-id projection from the
        // surviving assets (idempotent, whole-catalog).
        guard repairFilenameProviderIDsInTransaction(),
              failurePoint != .afterFilenameProjection else { return rollback() }

        return exec("COMMIT;")
    }

    /// P6 helper: the association recompute of `reconcileSidecarAssociations` with
    /// no per-item materialize and no yield — it only updates `associated_item_id`/
    /// `status` for every sidecar and returns the affected item ids so the caller
    /// rematerializes their winners in the same transaction.
    private func recomputeSidecarAssociationsInTransaction() -> (ok: Bool, affectedItemIDs: Set<String>) {
        var files: [PendingLocalMetadataFile] = []
        query("SELECT \(LocalMetadataRepository.pendingLocalMetadataFileColumns) FROM local_metadata_files ORDER BY rel_path;") { stmt in
            if let file = self.localRepo.materializePendingLocalMetadataFile(stmt) { files.append(file) }
        }
        var affected = Set<String>()
        for file in files {
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
            guard sqlite3_prepare_v2(db, """
                UPDATE local_metadata_files
                SET associated_item_id=?, status=?,
                    processed_fingerprint=CASE WHEN ?=1 THEN NULL ELSE processed_fingerprint END
                WHERE rel_path=?;
                """, -1, &stmt, nil) == SQLITE_OK else { return (false, affected) }
            bindOptText(stmt, 1, desiredItemID)
            bindText(stmt, 2, plan.status)
            sqlite3_bind_int64(stmt, 3, plan.clearProcessedFingerprint ? 1 : 0)
            bindText(stmt, 4, file.relPath)
            let stepped = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard stepped else { return (false, affected) }
            for itemID in Set([file.processedItemID, desiredItemID].compactMap { $0 }) {
                affected.insert(itemID)
            }
        }
        return (true, affected)
    }

    /// Transaction-bound twin of `materializeCachedLocalMetadata` — assumes an
    /// ambient transaction (no nested `BEGIN`), for use inside `finalizeCleanScan`.
    @discardableResult
    private func materializeCachedLocalMetadataInTransaction(itemID: String) -> Bool {
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
        return replaceLocalNFOMetadataInTransaction(
            itemID: itemID,
            candidates: ShareLocalMetadataWinnerResolver.resolve(sidecars)
        )
    }

    /// The next bounded slice of pending sidecars for the scheduled background
    /// pass, oldest-scanned first.
    func pendingLocalMetadataFiles(limit: Int) -> [PendingLocalMetadataFile] {
        ensureOpen()
        guard db != nil else { return [] }
        return localRepo.pendingLocalMetadataFiles(limit: limit, maxAttempts: Self.maxLocalAttempts)
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
        ensureOpen()
        return localRepo.sidecarStatus(relPath: relPath)
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
            let groupKey = readQueries.resolvedMovieGroupKey(mkey)
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
            SELECT \(LocalMetadataRepository.pendingLocalMetadataFileColumns)
            FROM local_metadata_files WHERE \(predicate);
            """, bind: { self.bindText($0, 1, value) }) { stmt in
                if let file = self.localRepo.materializePendingLocalMetadataFile(stmt) {
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
        query("SELECT \(LocalMetadataRepository.pendingLocalMetadataFileColumns) FROM local_metadata_files ORDER BY rel_path;") { stmt in
            if let file = self.localRepo.materializePendingLocalMetadataFile(stmt) {
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
        guard localRepo.replaceSidecarValueCache(relPath: relPath, fields: fields), exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        return true
    }

    @discardableResult
    func clearSidecarValueCache(relPath: String) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        return localRepo.clearSidecarValueCache(relPath: relPath)
    }

    /// The cached parsed field values for one sidecar (`nil` when never cached).
    func sidecarValueCache(relPath: String) -> [MetadataField: String] {
        ensureOpen()
        guard db != nil else { return [:] }
        return localRepo.sidecarValueCache(relPath: relPath)
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
        parserVersion: Int = ShareNFOParser.parserVersion,
        now: Date = Date()
    ) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        return localRepo.markSidecarProcessed(
            relPath: relPath, status: status, fingerprint: fingerprint,
            associatedItemID: associatedItemID, parserVersion: parserVersion, now: now
        )
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
        ensureOpen()
        guard db != nil else { return 0 }
        return localRepo.markSidecarsPendingForParserUpgrade(to: version)
    }

    /// Record a TRANSIENT transport failure: stays `pending`, bumps the bounded
    /// retry counter, never fabricates a successful local version.
    @discardableResult
    func markSidecarTransientFailure(relPath: String) -> Bool {
        ensureOpen()
        guard db != nil else { return false }
        return localRepo.markSidecarTransientFailure(relPath: relPath)
    }

    func resetPendingLocalMetadataAttempts() {
        ensureOpen()
        guard db != nil else { return }
        localRepo.resetPendingLocalMetadataAttempts()
    }

    private func replaceLocalNFOMetadata(
        itemID: String,
        candidates: [ShareLocalMetadataFieldCandidate],
        now: Date = Date()
    ) -> Bool {
        guard db != nil, normalizedMetadataReady else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        guard replaceLocalNFOMetadataInTransaction(itemID: itemID, candidates: candidates, now: now),
              exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        return true
    }

    /// Transaction-bound core of `replaceLocalNFOMetadata` — assumes an ambient
    /// transaction (no nested `BEGIN`/`COMMIT`), so the clean-scan transaction can
    /// call it directly. Replaces the whole `localNFO` lane for one item. Returns
    /// false without committing on any SQLite failure; the caller owns rollback.
    @discardableResult
    private func replaceLocalNFOMetadataInTransaction(
        itemID: String,
        candidates: [ShareLocalMetadataFieldCandidate],
        now: Date = Date()
    ) -> Bool {
        guard db != nil, normalizedMetadataReady else { return false }
        guard enrichmentRepo.replaceLocalNFOMetadataValues(
            itemID: itemID,
            candidates: candidates,
            now: now
        ) else { return false }
        localMetadataPresence.cached = nil
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
        return enrichmentRepo.writeLocalEnrichmentState(itemID: itemID, version: version, attempts: attempts)
    }

    func localEnrichmentState(itemID: String) -> (version: Int, attempts: Int)? {
        ensureOpen()
        guard db != nil else { return nil }
        return enrichmentRepo.localEnrichmentState(itemID: itemID)
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
        return enrichmentRepo.explicitProviderIDs(relPath: relPath)
    }

    /// Already-persisted local (NFO/filename) provider ids for `itemID`, seeded
    /// into the external resolver request so it can skip fuzzy title-based
    /// discovery where the provider supports exact-id resolution (see
    /// `ShareEnrichRequest.knownProviderIDs`).
    func localProviderIDs(forItemID itemID: String) -> [String: String] {
        ensureOpen()
        guard db != nil else { return [:] }
        return enrichmentRepo.localProviderIDs(forItemID: itemID)
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
        guard exec("BEGIN IMMEDIATE;") else { return }
        guard repairFilenameProviderIDsInTransaction(), exec("COMMIT;") else {
            _ = exec("ROLLBACK;")
            return
        }
    }

    /// Transaction-bound core of `repairFilenameProviderIDs` — computes the flat
    /// filename/explicit-id projection from the surviving assets and rewrites the
    /// `source='filename'` lane, assuming an ambient transaction (no nested
    /// `BEGIN`/`COMMIT`). Whole-catalog and idempotent. Returns false without
    /// committing on any SQLite failure; the caller owns rollback.
    @discardableResult
    private func repairFilenameProviderIDsInTransaction() -> Bool {
        guard db != nil, normalizedMetadataReady else { return false }
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
        guard ok else { return false }
        localMetadataPresence.cached = nil
        return true
    }

    // MARK: - Enrichment (scan-time metadata resolution, persisted)

    /// Logical items (movies + series) with no enrichment row at `version` yet,
    /// oldest-discovered first so a fresh library fills in a sensible order.
    func pendingEnrichment(
        version: Int,
        limit: Int,
        passStartedAt: Date? = nil
    ) -> [PendingEnrichment] {
        ensureOpen()
        guard db != nil else { return [] }
        return enrichmentRepo.pendingEnrichment(version: version, limit: limit, passStartedAt: passStartedAt)
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
        return enrichmentRepo.pendingEnrichmentCount(version: version, discoveredBefore: discoveredBefore)
    }

    /// The pending-enrichment request for a SINGLE catalog id (the item a user just
    /// opened), or `nil` when it's already enriched at `version`, isn't a logical
    /// movie/series, or is unknown. Lets the provider jump the viewed item to the
    /// front of the enrichment queue so its art/overview/ids persist promptly.
    func pendingEnrichment(forItemID id: String, version: Int) -> PendingEnrichment? {
        ensureOpen()
        return readQueries.pendingEnrichment(forItemID: id, version: version)
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
        let prior = enrichmentRepo.enrichmentVersionAndAttempts(itemID: itemID)
        let isReResolveAfterBump = prior != nil && prior?.version != version && record.isUsable
        let merged = isReResolveAfterBump
            ? record
            : EnrichmentRepository.merged(existing: readQueries.enrichmentRow(itemID: itemID), new: record)
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
        let normalizedWritten = projectionWritten && enrichmentRepo.writeMetadataValues(
            itemID: itemID,
            record: merged,
            refreshedAt: now,
            replaceExisting: true
        )
        let stateWritten = normalizedWritten && enrichmentRepo.writeEnrichmentState(
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
                let outcome = reconciler.reconcileSeriesByStrongID(
                    key: key,
                    ids: merged.providerIDs,
                    resolvedTitle: merged.title
                )
                derivedCatalogWritten = outcome.ok
                pendingMergedSeriesLocalRepairs.formUnion(outcome.mergedCanonicalIDs)
            }
            if derivedCatalogWritten,
               enrichmentSaveFailurePoint == .afterDerivedCatalogMutations {
                derivedCatalogWritten = false
            }
        }
        if derivedCatalogWritten, !pendingMergedSeriesLocalRepairs.isEmpty {
            derivedCatalogWritten = reassociateAllArtworkInTransaction()
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

    private func reclassifySeriesToAnime(seriesKey: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE assets SET library='anime' WHERE series_key=? AND kind='episode' AND library<>'anime';", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, seriesKey)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// JSON (de)serialization for persisted columns, used by the write/scan paths.
    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        CatalogJSON.encode(value)
    }
    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        CatalogJSON.decode(type, json)
    }

    // MARK: - Read path (build MediaItems)
    //
    // Read/query composition and item building live in `CatalogReadQueries` — a pure,
    // transaction-free helper over the same actor-confined `CatalogConnection`. The
    // store's public read API forwards there after `ensureOpen()`; the detailed
    // SQL/rationale comments live with each method in `CatalogReadQueries.swift`.

    /// Whether the catalog has any indexed content yet (false on a fresh share).
    func isEmpty() -> Bool { ensureOpen(); return readQueries.isEmpty() }

    /// Per-library counts so `libraries()` can hide an indexed library with no content.
    func libraryCounts() -> (movies: Int, tvSeries: Int, animeSeries: Int) {
        ensureOpen(); return readQueries.libraryCounts()
    }

    /// Recently added: movies + one entry per series, newest first (Home hot path).
    func latest(limit: Int) -> [MediaItem] { ensureOpen(); return readQueries.latest(limit: limit) }

    /// Free-text search across movie/episode/series titles.
    func search(query q: String, limit: Int) -> [MediaItem] {
        ensureOpen(); return readQueries.search(query: q, limit: limit)
    }

    /// Movie items for the Movies grid (paged, grouped, enrichment overlaid).
    func movies(offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen(); return readQueries.movies(offset: offset, limit: limit)
    }

    /// Distinct series items for a TV/Anime library, alphabetical (paged).
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
        ensureOpen(); return readQueries.series(in: library, offset: offset, limit: limit)
    }

    /// Exact number of distinct logical movies (for the grid's `totalCount`).
    func movieCount() -> Int { ensureOpen(); return readQueries.movieCount() }

    /// Exact number of distinct series in a TV/Anime library (zero for movies).
    func seriesCount(in library: CatalogLibrary) -> Int {
        ensureOpen(); return readQueries.seriesCount(in: library)
    }

    /// Season container items for a series.
    func seasons(seriesKey: String) -> [MediaItem] {
        ensureOpen(); return readQueries.seasons(seriesKey: seriesKey)
    }

    /// On-disk episode-title fingerprints for content-based series disambiguation.
    func episodeTitleHints(seriesKey: String, limit: Int = 12) -> [(season: Int, episode: Int, title: String)] {
        ensureOpen(); return readQueries.episodeTitleHints(seriesKey: seriesKey, limit: limit)
    }

    /// Distinct richer FILENAME-derived series titles (extra TVDB search candidates).
    func seriesSearchTitleAlternates(seriesKey: String, storedTitle: String, sampleLimit: Int = 24) -> [String] {
        ensureOpen()
        return readQueries.seriesSearchTitleAlternates(seriesKey: seriesKey, storedTitle: storedTitle, sampleLimit: sampleLimit)
    }

    /// The explicit TheTVDB id a series' folder/filenames declared via `[tvdb-####]`.
    func seriesEmbeddedTVDBID(seriesKey: String) -> String? {
        ensureOpen(); return readQueries.seriesEmbeddedTVDBID(seriesKey: seriesKey)
    }

    /// Episode items for one season of a series.
    func episodes(seriesKey: String, season: Int) -> [MediaItem] {
        ensureOpen(); return readQueries.episodes(seriesKey: seriesKey, season: season)
    }

    /// Resolve any catalog id to a rich `MediaItem`, or `nil` if unknown here.
    func item(id: String) -> MediaItem? { ensureOpen(); return readQueries.item(id: id) }

    /// The best default file to play for a logical movie when no version is named.
    func defaultMovieRelPath(forKey key: String) -> String? {
        ensureOpen(); return readQueries.defaultMovieRelPath(forKey: key)
    }

    /// Canonical watch-state id for a leaf id (folds movie files into `movie:<key>`).
    func canonicalItemID(_ id: String) -> String {
        ensureOpen(); return readQueries.canonicalItemID(id)
    }

    /// Stored watch-state ids for the requested items, mapped to their canonical ids.
    func watchStateAliases(for itemIDs: [String]) -> [String: String] {
        ensureOpen(); return readQueries.watchStateAliases(for: itemIDs)
    }

    /// Whether a legacy/raw `f:` id still has a live catalog row.
    func containsFileAsset(id: String) -> Bool {
        ensureOpen(); return readQueries.containsFileAsset(id: id)
    }

    // MARK: - Small SQLite helpers
    //
    // Thin forwarders onto the actor-confined `CatalogConnection`, kept so the store's
    // remaining write/scan call sites stay unchanged while the raw SQLite mechanics
    // live on the connection.

    @discardableResult
    private func exec(_ sql: String) -> Bool { connection.exec(sql) }

    private func hasColumn(table: String, column: String) -> Bool {
        connection.hasColumn(table: table, column: column)
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        connection.query(sql, bind: bind, row: row)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        CatalogConnection.bindText(stmt, idx, value)
    }
    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        CatalogConnection.bindOptText(stmt, idx, value)
    }
    private func bindOptInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        CatalogConnection.bindOptInt(stmt, idx, value)
    }
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        CatalogConnection.columnText(stmt, idx)
    }
    private func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        CatalogConnection.columnOptInt(stmt, idx)
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
