import Foundation
import CloudKit
import CoreModels
import CoreNetworking

// MARK: - CloudConfigSyncService (V3)
//
// The CloudKit "Stage 1" auto-sync layer, rebuilt on the pure `SyncLedger` (CoreModels)
// after two independent reviews condemned the V2 mirror. The ledger is the merge /
// conflict brain; this actor is the thin, CORRECT CloudKit glue around it:
//   • Local edits: capture a flat [recordName: canonicalBytes] map, `reconcileLocal`
//     into upload/delete plans, enqueue them, let CKSyncEngine send (automatic).
//   • Remote changes: decode fetched CKRecords → `applyFetched` → apply the EXACT
//     local changes to the app's stores (never re-derives/clobbers).
//   • Conflicts: CloudKit change tags detect them on send (`serverRecordChanged`);
//     the ledger resolves by mutation-boundary last-writer-wins.
//   • Deletions are durable (pendingDelete tombstones) and authoritative.
//   • Redownload is a full-resync lifecycle that can't resurrect peer deletions.
//   • Engine events are GENERATION-FENCED: a stale engine (after a rebuild) can never
//     mutate state.
//
// Automatic by design: `automaticallySync = true` + CKSyncEngine's own push
// subscription do the syncing; the manual affordances are just nudges. NO secrets.
public actor CloudConfigSyncService {

    // MARK: Dependencies

    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var isEnabled: @Sendable () -> Bool
        /// Capture the current canonical, NON-SECRET flat record map from the app's
        /// stores (recordName -> canonical value bytes). `fallback` is the ledger's
        /// last-known bytes per record: the app MUST return `fallback[name]` for any
        /// record it can't currently express locally (e.g. a setting whose profile
        /// hasn't been created yet, or a server it isn't signed into), so an
        /// out-of-order/partial capture never omits a record and triggers a spurious
        /// deletion of a peer's data.
        public var captureRecords: @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data]
        /// Apply the EXACT local changes the ledger dictates (nil value = delete).
        public var applyRecords: @Sendable (SyncLocalChanges) async -> Void
        /// Drop local state that was DERIVED from the previous iCloud account (e.g.
        /// synced-but-not-signed-in server descriptors) when the Apple ID changes, so
        /// the previous household's config is never re-published into the new account.
        public var onAccountSwitch: @Sendable () async -> Void
        /// Whether the app's stores are loaded enough to trust that an absent record is
        /// a genuine deletion (guards a hydrating capture from wiping every peer).
        public var isHydrated: @Sendable () -> Bool
        /// Where the ledger + engine state are persisted (per install/user container).
        public var stateFileURL: URL
        /// Optional MainActor sink for status updates.
        public var status: CloudSyncStatus?

        public init(
            containerIdentifier: String,
            stateFileURL: URL,
            isEnabled: @escaping @Sendable () -> Bool,
            captureRecords: @escaping @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data],
            applyRecords: @escaping @Sendable (SyncLocalChanges) async -> Void,
            onAccountSwitch: @escaping @Sendable () async -> Void = {},
            isHydrated: @escaping @Sendable () -> Bool = { true },
            status: CloudSyncStatus? = nil
        ) {
            self.containerIdentifier = containerIdentifier
            self.stateFileURL = stateFileURL
            self.isEnabled = isEnabled
            self.captureRecords = captureRecords
            self.applyRecords = applyRecords
            self.onAccountSwitch = onAccountSwitch
            self.isHydrated = isHydrated
            self.status = status
        }
    }

    private let config: Configuration
    private let container: CKContainer
    private var engine: CKSyncEngine?
    /// Bumped every time the engine is rebuilt; events from an older engine are
    /// ignored (generation fencing).
    private var engineGeneration = 0
    /// Set after an iCloud account SWITCH: blocks publishing until we've successfully
    /// fetched the new account's real state, so this device never uploads the previous
    /// household's config into a different Apple ID before learning what's there.
    private var suspendPublishUntilFetch = false
    /// True once this process has CONFIRMED the current account's server state (a
    /// successful fetch or real fetched data). Until then a device with no local
    /// baseline must not publish — stamping fresh edits over unknown server data would
    /// clobber peers. Gates EVERY normal publish path (S1), not just activate.
    private var didConfirmServerState = false
    /// True for the duration of a full resync. Publishing while `beginFullResync` has
    /// cleared the baselines would re-mark every record dirty and resurrect peer
    /// deletions, so all publishing is deferred until the resync ends/aborts (S3).
    private var isFullResyncing = false

    // Persisted across launches.
    private var ledger: SyncLedger
    private var engineState: CKSyncEngine.State.Serialization?

    public init(_ configuration: Configuration) {
        self.config = configuration
        self.container = CKContainer(identifier: configuration.containerIdentifier)
        let loaded = Self.loadPersisted(from: configuration.stateFileURL)
        self.ledger = loaded?.ledger ?? SyncLedger()
        self.engineState = loaded?.engineState
    }

    private func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: Status helpers

    private func setStatus(_ phase: CloudSyncStatus.Phase, syncedNow: Bool = false, error: String? = nil) {
        guard let status = config.status else { return }
        Task { @MainActor in
            if phase == .error { status.setError(error ?? "Couldn't sync", diagnostic: nil) }
            else { status.setPhase(phase, syncedNow: syncedNow) }
        }
    }

    private func setDiagnostic(_ detail: String) {
        PlozzLog.sync.error("CloudSync: \(detail)")
        guard let status = config.status else { return }
        Task { @MainActor in status.lastDiagnostic = detail }
    }

    private func reportRecordCount() {
        let count = ledger.count
        guard let status = config.status else { return }
        Task { @MainActor in status.syncedRecordCount = count }
    }

    private static func ckCodeName(_ error: CKError) -> String { "\(error.code) (\(error.code.rawValue))" }

    /// A fetch of the CURRENT account succeeded (or real data arrived): the server
    /// state is now known, so it's safe to lift a post-switch suspension and to let a
    /// baseline-less device publish. Single choke point for both publish gates.
    private func markServerStateConfirmed() {
        suspendPublishUntilFetch = false
        didConfirmServerState = true
    }

    // MARK: Lifecycle

    /// Bring the engine up (if enabled + an account is available), ensure the zone,
    /// FETCH the server's real state FIRST (so a fresh/behind device learns the truth
    /// before it can publish stale local data over a peer), then publish genuine local
    /// diffs. Safe to call repeatedly.
    public func activate() async {
        guard config.isEnabled() else { setStatus(.disabled); return }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        setStatus(.idle)
        await logAccountIdentity()
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))])
        await cleanupLegacyZonesIfNeeded()
        // Fetch before publish — the anti-clobber ordering.
        do { try await engine.fetchChanges(); markServerStateConfirmed() }
        catch { setDiagnostic("activate fetch: \(Self.describe(error))") }
        // publishLocalChanges enforces the suspend / baseline / resync gates itself, so
        // a fresh device whose fetch failed simply no-ops instead of clobbering.
        await publishLocalChanges()
        reportRecordCount()
    }

    /// One-time: delete the dead V1/V2 CloudKit zones so their stale records stop being
    /// dragged into every V3 fetch (noise + an inflated item count). Idempotent and
    /// guarded by a persisted flag so it runs at most once per install; a failure just
    /// retries next launch. Never touches the live V3 zone.
    private func cleanupLegacyZonesIfNeeded() async {
        let key = "com.plozz.cloudSync.didCleanupLegacyZones.\(config.containerIdentifier)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [], deleting: CloudSyncSchema.legacyZoneIDs)
            UserDefaults.standard.set(true, forKey: key)
            PlozzLog.sync.info("CloudSync: deleted legacy V1/V2 zones \(CloudSyncSchema.legacyZoneNames.joined(separator: ", "))")
        } catch {
            // A zone that doesn't exist yields a partial error — treat "nothing to
            // delete" as success so we don't retry forever.
            if let ck = error as? CKError, ck.code == .partialFailure || ck.code == .zoneNotFound {
                UserDefaults.standard.set(true, forKey: key)
                PlozzLog.sync.info("CloudSync: legacy zones already absent — cleanup marked done")
            } else {
                PlozzLog.sync.error("CloudSync: legacy zone cleanup failed (will retry): \(Self.describe(error))")
            }
        }
    }

    private func logAccountIdentity() async {        do {
            let status = try await container.accountStatus()
            let userID = try await container.userRecordID()
            let short = String(userID.recordName.prefix(10))
            PlozzLog.sync.info("CloudSync: iCloud status=\(status.rawValue) userID=\(short)…")
            if let s = config.status { await MainActor.run { s.accountTag = short } }
        } catch {
            PlozzLog.sync.error("CloudSync: could not read iCloud identity: \(error.localizedDescription)")
        }
    }

    /// Lightweight foreground pull. Fetch FIRST (learn the server's truth), then
    /// publish genuine local diffs and send — the anti-clobber ordering.
    public func fetchNow() async {
        guard config.isEnabled(), await accountIsAvailable() else { return }
        ensureEngine()
        guard let engine else { return }
        if (try? await engine.fetchChanges()) != nil { markServerStateConfirmed() }
        await publishLocalChanges()
        try? await engine.sendChanges()
        reportRecordCount()
    }

    /// Manual "Sync Now": fetch → publish → send.
    public func syncNow() async {
        guard config.isEnabled() else { setStatus(.disabled); return }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        guard let engine else { return }
        setStatus(.syncing)
        var syncError: Error?
        do { try await engine.fetchChanges(); markServerStateConfirmed() }
        catch { syncError = error }
        await publishLocalChanges()
        do { try await engine.sendChanges() } catch { if syncError == nil { syncError = error } }
        reportRecordCount()
        if let syncError {
            setDiagnostic("sync: \(Self.describe(syncError))")
            setStatus(.error, error: (syncError as NSError).localizedDescription)
        } else {
            setStatus(.idle, syncedNow: true)
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"]
        if let ck = error as? CKError {
            if let partials = ck.partialErrorsByItemID, !partials.isEmpty {
                let items = partials.prefix(4).map { "\($0.key): \(($0.value as NSError).code)" }.joined(separator: ", ")
                parts.append("partials[\(partials.count)]: \(items)")
            }
            if let retry = ck.retryAfterSeconds { parts.append("retryAfter=\(retry)s") }
        }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(u.domain) code=\(u.code) \(u.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: Publish (local → cloud)

    /// Capture local state, reconcile into the ledger, and enqueue the minimal
    /// save/delete plan. No-op when disabled or unchanged.
    ///
    /// `bypassBaselineGate` is set ONLY by reset/reseed, which has just made the
    /// server state known (it deleted all records), so publishing local as fresh
    /// creates is deliberate and safe.
    public func publishLocalChanges(bypassBaselineGate: Bool = false) async {
        guard config.isEnabled(), let engine else { return }
        guard !suspendPublishUntilFetch else {
            PlozzLog.sync.info("CloudSync: publish skipped — suspended pending account-switch fetch")
            return
        }
        // S3: never publish while a full resync has the baselines cleared — it would
        // re-mark everything dirty and resurrect peer deletions.
        guard !isFullResyncing else {
            PlozzLog.sync.info("CloudSync: publish skipped — full resync in progress")
            return
        }
        // S1: a device that hasn't confirmed the current account's server state AND
        // has no local baseline must not publish — fresh-stamped creates would clobber
        // unknown remote data. (activate/fetchNow/syncNow set didConfirmServerState on a
        // successful fetch; real fetched data sets it too.)
        guard bypassBaselineGate || didConfirmServerState || ledger.hasServerBaseline else {
            PlozzLog.sync.info("CloudSync: publish deferred — server state not yet confirmed on a baseline-less device")
            return
        }
        // C2 (reentrancy anti-clobber): `captureRecords` awaits a hop to the app's
        // @MainActor, suspending this actor. A queued fetched-changes apply can run in
        // that window and advance the ledger's server baseline (and the app's stores).
        // If we then reconciled the PRE-apply snapshot, a stale local value would be
        // re-stamped newer and clobber the peer edit that just landed. So we re-capture
        // until no remote-driven mutation interleaved with the capture; reconcile is
        // synchronous and therefore atomic once we have a clean snapshot.
        var desired: [SyncRecordID: Data] = [:]
        var stabilized = false
        for _ in 0..<4 {
            let rev = ledger.remoteRevision
            desired = await config.captureRecords(ledger.syncedValues())
            if ledger.remoteRevision == rev { stabilized = true; break }
        }
        // S4: if a remote apply kept interleaving every capture, the snapshot may
        // predate the latest baseline. Do NOT reconcile an unverified capture (it could
        // clobber the just-arrived change) — skip this publish; a later one retries.
        guard stabilized else {
            PlozzLog.sync.info("CloudSync: publish deferred — capture kept racing remote applies; will retry")
            return
        }
        let plan = ledger.reconcileLocal(
            desired: desired, now: nowMillis(), synthesizeDeletions: config.isHydrated())
        if !plan.refusedDeletions.isEmpty {
            setDiagnostic("refused \(plan.refusedDeletions.count) deletion(s) — capture looked incomplete; not wiping peers")
        }
        guard !plan.isEmpty else {
            persist()
            PlozzLog.sync.info("CloudSync: publish — nothing changed")
            return
        }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for up in plan.uploads { pending.append(.saveRecord(CloudSyncSchema.recordID(forRecordName: up.recordName))) }
        for name in plan.deletes { pending.append(.deleteRecord(CloudSyncSchema.recordID(forRecordName: name))) }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        reportRecordCount()
        PlozzLog.sync.info("CloudSync: queued \(plan.uploads.count) save(s), \(plan.deletes.count) delete(s)")
    }

    /// Publish and immediately send is intentionally NOT used — forcing sendChanges
    /// from the debounce raced CKSyncEngine's own scheduler and crashed on-device.
    /// `automaticallySync` sends queued changes; `syncNow`/`fetchNow` force it.

    /// Opt-out: erase this app's synced config from iCloud but KEEP the zone, so peers
    /// receive normal record deletions (never a zone-delete that strands their tokens).
    public func deleteAllServerData() async {
        guard let engine else { return }
        let names = ledger.entries.keys
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for name in names { pending.append(.deleteRecord(CloudSyncSchema.recordID(forRecordName: name))) }
        engine.state.add(pendingRecordZoneChanges: pending)
        try? await engine.sendChanges()
        ledger = SyncLedger()
        persist()
    }

    /// Erase this app's synced config from iCloud and RE-SEED it from THIS device's
    /// current local config — the "Reset Synced Data" action. Deletes records (keeps
    /// the zone so peers get normal deletions), clears the ledger, then republishes
    /// local as fresh creates. Local config is never touched.
    public func resetAndReseed() async {
        guard config.isEnabled(), await accountIsAvailable() else { return }
        setStatus(.syncing)
        await deleteAllServerData()   // deletes records + clears the ledger
        rebuildEngine()
        // Server state is known (just emptied), so bypass the baseline gate to re-seed.
        await publishLocalChanges(bypassBaselineGate: true)
        do {
            try await engine?.sendChanges()
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: reset + reseeded from this device")
        } catch {
            setDiagnostic("reset: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    /// Repair a device stuck not-receiving: full-resync lifecycle. Resets ONLY the
    /// fetch token (keeps local values + dirty edits + pending deletes), re-fetches the
    /// whole zone, and finalizes records a COMPLETE server snapshot no longer contains
    /// as deletions — so a peer's delete can never be resurrected. Non-destructive to
    /// the shared cloud data.
    public func redownloadFromCloud() async {
        guard config.isEnabled(), await accountIsAvailable() else { setStatus(.signedOut); return }
        setStatus(.syncing)
        PlozzLog.sync.info("CloudSync: redownload — full resync (keep local, reset token)")
        // S3: block all publishing while the baselines are cleared, so a concurrent
        // observation/manual publish can't re-mark everything dirty and resurrect
        // peer deletions. Lifted in every exit path below.
        isFullResyncing = true
        ledger.beginFullResync()
        rebuildEngine(resetState: true)   // nil token ⇒ COMPLETE re-fetch; fences old events
        guard let engine else { isFullResyncing = false; setStatus(.error, error: "engine unavailable"); return }
        do {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))])
            try await engine.fetchChanges()
            markServerStateConfirmed()
            // Only NOW — after a confirmed complete fetch — is it safe to finalize
            // unseen previously-synced records as deletions.
            let finalized = ledger.endFullResync()
            isFullResyncing = false
            persist(); reportRecordCount()
            if !finalized.isEmpty { await config.applyRecords(finalized) }
            // Requeue anything still dirty / pending-delete without re-stamping.
            var pending: [CKSyncEngine.PendingRecordZoneChange] = []
            pending += ledger.pendingUploads().map { .saveRecord(CloudSyncSchema.recordID(forRecordName: $0.recordName)) }
            pending += ledger.pendingDeletes().map { .deleteRecord(CloudSyncSchema.recordID(forRecordName: $0)) }
            if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: pending); try await engine.sendChanges() }
            // Replay one publish for any genuine local edits made during the resync
            // (they were deferred by the isFullResyncing gate).
            await publishLocalChanges()
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: redownload complete — \(ledger.count) record(s)")
        } catch {
            // A FAILED / incomplete fetch must NOT be finalized as a full snapshot
            // (that would delete records the fetch simply didn't reach). Abort the
            // resync WITHOUT producing any deletions; a later successful fetch
            // re-establishes the true baseline.
            ledger.abortFullResync()
            isFullResyncing = false
            persist()
            setDiagnostic("redownload: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    // MARK: Engine setup

    private func ensureEngine() {
        guard engine == nil else { return }
        rebuildEngine()
    }

    private func rebuildEngine() {
        rebuildEngine(resetState: false)
    }

    /// Rebuild the engine. When `resetState` is true the persisted CKSyncEngine state
    /// (INCLUDING the zone change token) is discarded, so the next `fetchChanges` is a
    /// COMPLETE zone re-fetch rather than an incremental delta — required for a valid
    /// full resync (`redownloadFromCloud`). Otherwise the change token is preserved.
    private func rebuildEngine(resetState: Bool) {
        engineGeneration += 1
        if resetState { engineState = nil }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: engineState, delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        PlozzLog.sync.info("CloudSync: engine initialized (gen \(engineGeneration), resetState=\(resetState))")
    }

    private func accountIsAvailable() async -> Bool {
        do { return try await container.accountStatus() == .available }
        catch { PlozzLog.sync.error("CloudSync: accountStatus failed: \(error.localizedDescription)"); return false }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var ledger: SyncLedger
        var engineState: CKSyncEngine.State.Serialization?
    }

    private static func loadPersisted(from url: URL) -> Persisted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private func persist() {
        let snapshot = Persisted(ledger: ledger, engineState: engineState)
        do {
            try FileManager.default.createDirectory(
                at: config.stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: config.stateFileURL, options: .atomic)
        } catch {
            PlozzLog.sync.error("CloudSync: failed to persist state: \(error.localizedDescription)")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudConfigSyncService: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // Generation fence: ignore events from a stale engine (post-rebuild).
        guard syncEngine === engine else {
            PlozzLog.sync.info("CloudSync: ignoring event from a stale engine")
            return
        }
        switch event {
        case .stateUpdate(let e):
            engineState = e.stateSerialization
            persist()
        case .accountChange(let e):
            await handleAccountChange(e)
        case .fetchedRecordZoneChanges(let e):
            await handleFetchedRecordZoneChanges(e)
        case .sentRecordZoneChanges(let e):
            await handleSentRecordZoneChanges(e, syncEngine: syncEngine)
        case .sentDatabaseChanges(let e):
            for failure in e.failedZoneSaves {
                setDiagnostic("zone save failed: \(Self.ckCodeName(failure.error))")
            }
        case .fetchedDatabaseChanges(let e):
            handleFetchedDatabaseChanges(e)
        case .willFetchChanges, .willSendChanges:
            setStatus(.syncing)
        case .didFetchChanges, .didSendChanges:
            setStatus(.idle, syncedNow: true)
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            PlozzLog.sync.info("CloudSync: unknown event")
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Generation fence: a stale engine (kept alive by automaticallySync after a
        // rebuild) must not produce a batch — its saves would use stale tags/values
        // and its completion event is ignored, diverging cloud from ledger state.
        guard syncEngine === engine else {
            PlozzLog.sync.info("CloudSync: ignoring batch request from a stale engine")
            return nil
        }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let entries = ledger.entries
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            let name = recordID.recordName
            guard let entry = entries[name], !entry.pendingDelete else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let base = CloudSyncSystemFields.record(from: entry.systemFields)
                ?? CKRecord(recordType: CloudSyncSchema.recordType, recordID: recordID)
            SyncUpload(recordName: name, value: entry.localValue,
                       editedAt: entry.editedAt, systemFields: entry.systemFields).populate(base)
            return base
        }
    }

    // MARK: Event handlers

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            // Fires on EVERY engine init for the SAME account too. Do NOTHING to the
            // ledger and never republish — the persisted ledger already reflects the
            // server, and the engine fetches/reconciles on its own. (Wiping+republishing
            // here was THE V2 clobber.)
            PlozzLog.sync.info("CloudSync: accountChange signIn — keeping ledger, no republish")
        case .switchAccounts:
            // A different Apple ID ⇒ a different private DB. Forget server bookkeeping
            // so we don't assume records exist there. CRITICAL: also drop state DERIVED
            // from the previous account (synced-but-not-signed-in server descriptors)
            // and SUSPEND publishing until we've fetched the new account — otherwise
            // this device would upload the previous household's config into the new
            // Apple ID. This device's OWN local config (signed-in accounts, profiles)
            // is kept; it legitimately belongs to the device.
            PlozzLog.sync.info("CloudSync: accountChange switchAccounts — clearing ledger + remote-derived state, suspending publish")
            ledger = SyncLedger()
            suspendPublishUntilFetch = true
            persist()
            await config.onAccountSwitch()
        case .signOut:
            ledger = SyncLedger()
            suspendPublishUntilFetch = true
            persist()
            setStatus(.signedOut)
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var incoming: [SyncRemoteRecord] = []
        for mod in event.modifications {
            if let rec = SyncRemoteRecord(ckRecord: mod.record) {
                incoming.append(rec)
            } else {
                // Never silently drop: a rejected record is a real signal (old-schema or
                // malformed). Logged, not consumed as data.
                PlozzLog.sync.error("CloudSync: fetch ignored non-V3 record \(mod.record.recordID.recordName) type=\(mod.record.recordType) zone=\(mod.record.recordID.zoneID.zoneName)")
            }
        }
        var deletedNames: [SyncRecordID] = []
        for del in event.deletions { deletedNames.append(del.recordID.recordName) }

        guard !incoming.isEmpty || !deletedNames.isEmpty else { return }
        let changes = ledger.applyFetched(saved: incoming, deleted: deletedNames, now: nowMillis())
        persist()
        reportRecordCount()
        if !changes.isEmpty {
            await config.applyRecords(changes)
            PlozzLog.sync.info("CloudSync: applied \(changes.count) change(s) from \(incoming.count) fetched, \(deletedNames.count) deletion(s)")
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine
    ) async {
        for saved in event.savedRecords {
            let value = (saved[CloudSyncSchema.fieldValue] as? Data) ?? Data()
            let editedAt = CloudSyncSchema.int64(saved[CloudSyncSchema.fieldEditedAt]) ?? 0
            ledger.applySendSuccess(recordName: saved.recordID.recordName, savedValue: value,
                                    savedEditedAt: editedAt, systemFields: CloudSyncSystemFields.archive(saved))
        }
        for id in event.deletedRecordIDs { ledger.applyDeleteSuccess(id.recordName) }

        var applied: SyncLocalChanges = [:]
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zoneRetry: [CKSyncEngine.PendingDatabaseChange] = []

        for failure in event.failedRecordSaves {
            let record = failure.record
            let name = record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord,
                      let rec = SyncRemoteRecord(ckRecord: serverRecord) else {
                    // The server reported a conflict but we can't read/decode its
                    // record (nil serverRecord, or an older/foreign schema). DON'T drop
                    // the local edit — clear the stale tag and retry so a subsequent
                    // fetch+reconcile resolves it. Silently removing the pending change
                    // would permanently lose this device's edit.
                    ledger.clearServerRecord(name)
                    retry.append(.saveRecord(record.recordID))
                    setDiagnostic("serverRecordChanged without a decodable serverRecord for \(name) — retrying")
                    continue
                }
                if let (rn, val) = ledger.applySendConflict(rec, now: nowMillis()) {
                    applied.updateValue(val, forKey: rn)   // server won → apply its value
                } else {
                    retry.append(.saveRecord(record.recordID))  // we won → retry with fresh tag
                }
            case .zoneNotFound:
                zoneRetry.append(.saveZone(CKRecordZone(zoneID: record.recordID.zoneID)))
                ledger.clearServerRecord(name)
                retry.append(.saveRecord(record.recordID))
            case .unknownItem:
                // The record we tried to update doesn't exist — re-create (config policy).
                ledger.clearServerRecord(name)
                retry.append(.saveRecord(record.recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled:
                PlozzLog.sync.info("CloudSync: retryable save error for \(name): \(Self.ckCodeName(failure.error))")
            default:
                setDiagnostic("save failed for \(name): \(Self.ckCodeName(failure.error))")
            }
        }

        for (id, error) in event.failedRecordDeletes {
            if error.code == .unknownItem { ledger.applyDeleteSuccess(id.recordName) }  // already gone
            else { retry.append(.deleteRecord(id)) }
        }

        if !zoneRetry.isEmpty { syncEngine.state.add(pendingDatabaseChanges: zoneRetry) }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        persist()
        reportRecordCount()
        if !applied.isEmpty { await config.applyRecords(applied) }
    }

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        // Our zone was deleted on the server (a peer opted out / reset). Clear the ledger
        // so we re-derive from local on the next publish; local config is untouched. We
        // never delete the zone ourselves, so this is rare.
        for deletion in event.deletions where deletion.zoneID.zoneName == CloudSyncSchema.zoneName {
            ledger = SyncLedger()
            persist()
        }
    }
}
