import Foundation
import CloudKit
import CoreModels
import CoreNetworking

// MARK: - CloudConfigSyncService
//
// The CloudKit "Stage 1" auto-sync layer: keeps the NON-SECRET household setup
// (server descriptors, profiles, per-profile settings + membership) in sync across
// one Apple ID's devices via `CKSyncEngine` on the private database.
//
// Design (verified against Apple's `sample-cloudkit-sync-engine` + WWDC22 110384
// "Mapping Apple TV users to app profiles"):
//   • The pure `CloudSyncMirror` (CoreModels) is the merge/versioning brain; this
//     actor is the thin CloudKit glue around it.
//   • LOCAL-FIRST: Plozz's real config lives in the app's stores; CloudKit is a
//     MIRROR, not the source of truth. Unlike Apple's sample, an account change
//     (switching the signed-in Apple ID, e.g. via a tvOS system-user switch) NEVER
//     deletes local data — the household roster lives in the user-independent
//     Keychain and belongs to the box. We just re-point at the new Apple ID's DB
//     and re-derive the snapshot from the unchanged local state.
//   • NO SECRETS: only `SyncConfigSnapshot` payloads travel; tokens/passwords are
//     never representable in a `CloudSyncRecord`.
//   • Loop-prevention/idempotency come from the mirror: applying a remote change
//     leaves the mirror equal to local, so the app's follow-up change signal
//     produces an empty publish.
//
// The app wires this with two closures: `localSnapshot` (build the current
// non-secret snapshot) and `applyRemoteSnapshot` (merge an incoming snapshot into
// the app's stores, config-only — never signs a device in). Both hop to the
// MainActor inside the app.
public actor CloudConfigSyncService {

    // MARK: Dependencies

    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var isEnabled: @Sendable () -> Bool
        public var localSnapshot: @Sendable () async -> SyncConfigSnapshot
        public var applyRemoteSnapshot: @Sendable (SyncConfigSnapshot) async -> Void
        /// Where the mirror + engine state are persisted (per install/user container).
        public var stateFileURL: URL
        /// Optional MainActor sink the service pushes status updates to.
        public var status: CloudSyncStatus?

        public init(
            containerIdentifier: String,
            stateFileURL: URL,
            isEnabled: @escaping @Sendable () -> Bool,
            localSnapshot: @escaping @Sendable () async -> SyncConfigSnapshot,
            applyRemoteSnapshot: @escaping @Sendable (SyncConfigSnapshot) async -> Void,
            status: CloudSyncStatus? = nil
        ) {
            self.containerIdentifier = containerIdentifier
            self.stateFileURL = stateFileURL
            self.isEnabled = isEnabled
            self.localSnapshot = localSnapshot
            self.applyRemoteSnapshot = applyRemoteSnapshot
            self.status = status
        }
    }

    private let config: Configuration
    private let container: CKContainer
    private var engine: CKSyncEngine?

    // Persisted across launches.
    private var mirror: CloudSyncMirror
    private var engineState: CKSyncEngine.State.Serialization?
    /// recordName -> archived CKRecord system fields (change tag) for conflict-safe saves.
    private var systemFields: [String: Data]

    public init(_ configuration: Configuration) {
        self.config = configuration
        self.container = CKContainer(identifier: configuration.containerIdentifier)
        let loaded = Self.loadPersisted(from: configuration.stateFileURL)
        self.mirror = loaded?.mirror ?? CloudSyncMirror()
        self.engineState = loaded?.engineState
        self.systemFields = loaded?.systemFields ?? [:]
    }

    // MARK: Lifecycle

    /// Push a status update onto the MainActor status object, if one is wired.
    private func setStatus(_ phase: CloudSyncStatus.Phase, syncedNow: Bool = false, error: String? = nil) {
        guard let status = config.status else { return }
        Task { @MainActor in
            if phase == .error {
                status.setError(error ?? "Couldn't sync", diagnostic: nil)
            } else {
                status.setPhase(phase, syncedNow: syncedNow)
            }
        }
    }

    /// Record a PERSISTENT diagnostic detail (survives the phase flicker). Does NOT
    /// itself flip to the error phase — a self-healing conflict logs quietly.
    private func setDiagnostic(_ detail: String) {
        PlozzLog.sync.error("CloudSync: \(detail)")
        guard let status = config.status else { return }
        Task { @MainActor in status.lastDiagnostic = detail }
    }

    /// Push the current mirror record count to the status object so the UI can show
    /// "N items in iCloud" — a device stuck at a lower count than its peers is the
    /// clearest signal it isn't receiving.
    private func reportRecordCount() {
        let count = mirror.records.count
        guard let status = config.status else { return }
        Task { @MainActor in status.syncedRecordCount = count }
    }

    /// Log every record the mirror holds with its `editedAt`, so the SAME record's
    /// timestamp can be compared across devices — the definitive way to see whether
    /// an edit reached this device and who "wins" a conflict. Diagnostic only.
    private func logMirror(_ tag: String) {
        let items = mirror.records.values
            .sorted { $0.recordName < $1.recordName }
            .map { "\($0.recordName)@\($0.editedAt)" }
            .joined(separator: " | ")
        PlozzLog.sync.info("CloudSync[\(tag)] mirror(\(mirror.records.count)): \(items)")
    }

    /// Human-readable CKError code name for a save failure.
    private static func ckCodeName(_ error: CKError) -> String {
        "\(error.code) (\(error.code.rawValue))"
    }

    /// Bring the sync engine up (if the feature is enabled and an iCloud account is
    /// available), ensure the zone exists, and push any local config the mirror has
    /// not yet uploaded. Safe to call repeatedly.
    public func activate() async {
        guard config.isEnabled() else {
            PlozzLog.sync.info("CloudSync: not activating — feature disabled")
            setStatus(.disabled)
            return
        }
        guard await accountIsAvailable() else {
            PlozzLog.sync.info("CloudSync: not activating — no usable iCloud account")
            setStatus(.signedOut)
            return
        }
        ensureEngine()
        setStatus(.idle)
        // Log the iCloud identity this device syncs as, so a mismatched Apple ID
        // across devices (which silently syncs to a different private DB) is
        // diagnosable — the classic "one device never receives" cause.
        await logAccountIdentity()
        // Heal any previously-dropped applies: reconcile LOCAL to what the mirror
        // already knows BEFORE publishing. Without this, a mirror that's ahead of
        // local (e.g. an earlier apply was skipped) would make the next publish
        // upload the stale local value over the good synced one — a revert loop.
        if !mirror.records.isEmpty {
            await config.applyRemoteSnapshot(mirror.snapshot)
        }
        // Ensure our custom zone exists, then reconcile local -> cloud.
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))])
        await publishLocalChanges()
        reportRecordCount()
    }

    /// Log (and surface) the CloudKit user-record id + account status so the SAME
    /// value across devices can be confirmed — different ids ⇒ different Apple IDs ⇒
    /// they can never see each other's data.
    private func logAccountIdentity() async {
        do {
            let status = try await container.accountStatus()
            let userID = try await container.userRecordID()
            let short = String(userID.recordName.prefix(10))
            PlozzLog.sync.info("CloudSync: iCloud account status=\(status.rawValue) userID=\(short)…")
            if let s = config.status {
                await MainActor.run { s.accountTag = short }
            }
        } catch {
            PlozzLog.sync.error("CloudSync: could not read iCloud identity: \(error.localizedDescription)")
        }
    }

    /// Lightweight foreground pull: publish pending local changes, fetch remote
    /// changes, then send once more so any records this device won on merge
    /// (`toPush`, enqueued during fetch) actually go out. Used on app activation.
    public func fetchNow() async {
        guard config.isEnabled(), await accountIsAvailable() else { return }
        ensureEngine()
        guard let engine else { return }
        await publishLocalChanges()
        try? await engine.fetchChanges()
        try? await engine.sendChanges()   // flush toPush from the fetch
        reportRecordCount()
    }

    /// Force an immediate two-way sync, for a manual "Sync Now". Order is
    /// publish → FETCH → send, so a receiver pulls the latest first, and any records
    /// this device wins on merge (`toPush`) are pushed back in the same pass.
    public func syncNow() async {
        guard config.isEnabled() else { setStatus(.disabled); return }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        guard let engine else { return }
        setStatus(.syncing)
        logMirror("syncNow:before")
        await publishLocalChanges()

        var syncError: Error?
        // Fetch FIRST (pull remote + enqueue toPush), then send (push local edits +
        // toPush). Each runs regardless of the other's outcome.
        do { try await engine.fetchChanges(); PlozzLog.sync.info("CloudSync: syncNow fetch done") }
        catch { syncError = error; PlozzLog.sync.error("CloudSync: syncNow fetch FAILED: \(Self.describe(error))") }
        do { try await engine.sendChanges(); PlozzLog.sync.info("CloudSync: syncNow send done") }
        catch { if syncError == nil { syncError = error }; PlozzLog.sync.error("CloudSync: syncNow send FAILED: \(Self.describe(error))") }
        reportRecordCount()
        logMirror("syncNow:after")

        if let syncError {
            // The engine auto-retries transient conflicts, and its own did*Changes
            // events will flip us back to idle if that succeeds — so this error is
            // debounced and only surfaces if it's still unresolved shortly after.
            setDiagnostic("sync: \(Self.describe(syncError))")
            setStatus(.error, error: (syncError as NSError).localizedDescription)
        } else {
            setStatus(.idle, syncedNow: true)
        }
    }

    /// Unwrap a CloudKit / sync error into a readable chain: domain, code, message,
    /// any underlying error, and any per-item partial errors — the detail the
    /// generic "Failed to send changes" wrapper hides.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"]
        if let ck = error as? CKError {
            if let partials = ck.partialErrorsByItemID, !partials.isEmpty {
                let items = partials.prefix(4).map { key, value in
                    let e = value as NSError
                    return "\(key): \(e.domain) \(e.code)"
                }.joined(separator: ", ")
                parts.append("partials[\(partials.count)]: \(items)")
            }
            if let retry = ck.retryAfterSeconds { parts.append("retryAfter=\(retry)s") }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) code=\(underlying.code) \(underlying.localizedDescription)")
            if let deepest = underlying.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("deepest: \(deepest.domain) code=\(deepest.code) \(deepest.localizedDescription)")
            }
        }
        return parts.joined(separator: " | ")
    }

    /// The app calls this whenever the non-secret config changes (same signal that
    /// refreshes the presence beacon). Diffs local against the mirror and enqueues
    /// the minimal set of record saves/deletes. No-op when disabled or unchanged.
    public func publishLocalChanges() async {
        guard config.isEnabled(), let engine else { return }
        let local = await config.localSnapshot()
        let plan = mirror.publish(local: local)
        guard !plan.isEmpty else {
            PlozzLog.sync.info("CloudSync: publish — nothing changed")
            return
        }

        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for rec in plan.saves { pending.append(.saveRecord(CloudSyncSchema.recordID(forRecordName: rec.recordName))) }
        for name in plan.deletes {
            pending.append(.deleteRecord(CloudSyncSchema.recordID(forRecordName: name)))
            systemFields[name] = nil
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        reportRecordCount()
        let saveDetail = plan.saves.map { "\($0.recordName)@\($0.editedAt)" }.joined(separator: ", ")
        let deleteDetail = plan.deletes.isEmpty ? "" : " [deletes: \(plan.deletes.joined(separator: ", "))]"
        PlozzLog.sync.info("CloudSync: queued \(plan.saves.count) save(s) [\(saveDetail)], \(plan.deletes.count) delete(s)\(deleteDetail)")
    }

    /// Opt-out: remove all of THIS app's synced config from the current Apple ID's
    /// private DB (deletes the zone). Local data is untouched (local-first).
    public func deleteAllServerData() async {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(CloudSyncSchema.zoneID)])
        mirror = CloudSyncMirror()
        systemFields = [:]
        persist()
        try? await engine.sendChanges()
    }

    /// Repair a device that has STOPPED RECEIVING (its CKSyncEngine change token got
    /// stuck "caught up", so `fetchChanges` returns nothing even though peers have
    /// newer records — the "iPad updates, iPhone never does" bug). This resets ONLY
    /// the engine's fetch token and re-fetches the whole zone; it deliberately KEEPS
    /// the mirror.
    ///
    /// Why keep the mirror: the mirror holds each record's true `editedAt` (real
    /// edit time). If we cleared it and re-published local, this device's STALE
    /// local values would be re-stamped with a fresh "now" timestamp and then WIN
    /// last-writer-wins against peers' genuinely-newer edits — clobbering good data
    /// on the server (the bug that made "Reset Synced Data" make things worse).
    /// Keeping the mirror means the re-fetched peer records merge against their real
    /// timestamps and correctly win, and a follow-up publish sees "nothing changed".
    public func redownloadFromCloud() async {
        guard config.isEnabled(), await accountIsAvailable() else { setStatus(.signedOut); return }
        setStatus(.syncing)
        PlozzLog.sync.info("CloudSync: redownload — resetting fetch token, KEEPING mirror, re-fetching all")
        // Tear down the engine and forget ONLY the stuck fetch token. Mirror and
        // systemFields are preserved so real edit timestamps and change tags survive.
        engine = nil
        engineState = nil
        persist()
        // Rebuild with stateSerialization = nil ⇒ the engine re-fetches from scratch.
        ensureEngine()
        guard let engine else { setStatus(.error, error: "engine unavailable"); return }
        do {
            try await engine.fetchChanges()   // merges into the kept mirror by real editedAt
            reportRecordCount()
            logMirror("redownload:after")
            // Push the merged snapshot into the app's stores so the UI reflects it.
            if !mirror.records.isEmpty {
                await config.applyRemoteSnapshot(mirror.snapshot)
            }
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: redownload complete — \(mirror.records.count) record(s)")
        } catch {
            setDiagnostic("redownload: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    /// Reset a corrupted/divergent sync: wipe the CloudKit zone AND this device's
    /// mirror+tags, then re-seed the zone from THIS device's current local config.
    /// Other devices see the zone deletion, clear their mirrors, and re-converge —
    /// a clean slate. Local config is never touched.
    public func resetAndReseed() async {
        guard config.isEnabled(), await accountIsAvailable() else { return }
        ensureEngine()
        guard let engine else { return }
        setStatus(.syncing)
        // 1. Delete the zone + clear all local sync bookkeeping.
        engine.state.add(pendingDatabaseChanges: [.deleteZone(CloudSyncSchema.zoneID)])
        mirror = CloudSyncMirror()
        systemFields = [:]
        persist()
        try? await engine.sendChanges()
        // 2. Recreate the zone and re-upload this device's config from scratch.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncSchema.zoneID))])
        await publishLocalChanges()
        do {
            try await engine.sendChanges()
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: reset + reseeded from this device")
        } catch {
            setDiagnostic("reset: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    // MARK: Engine setup

    private func ensureEngine() {
        guard engine == nil else { return }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: engineState,
            delegate: self
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        PlozzLog.sync.info("CloudSync: engine initialized")
    }

    private func accountIsAvailable() async -> Bool {
        do { return try await container.accountStatus() == .available }
        catch {
            PlozzLog.sync.error("CloudSync: accountStatus failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var mirror: CloudSyncMirror
        var engineState: CKSyncEngine.State.Serialization?
        var systemFields: [String: Data]
    }

    private static func loadPersisted(from url: URL) -> Persisted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private func persist() {
        let snapshot = Persisted(mirror: mirror, engineState: engineState, systemFields: systemFields)
        do {
            try FileManager.default.createDirectory(
                at: config.stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
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
        switch event {
        case .stateUpdate(let e):
            engineState = e.stateSerialization
            persist()

        case .accountChange(let e):
            await handleAccountChange(e)

        case .fetchedRecordZoneChanges(let e):
            await handleFetchedRecordZoneChanges(e)

        case .sentRecordZoneChanges(let e):
            handleSentRecordZoneChanges(e, syncEngine: syncEngine)

        case .sentDatabaseChanges(let e):
            // A failed ZONE save cascades to every record — surface it.
            for failure in e.failedZoneSaves {
                setDiagnostic("zone save failed: \(Self.ckCodeName(failure.error)) — \(failure.error.localizedDescription)")
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
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // Capture Sendable snapshots so the record provider never touches actor
        // state or a non-Sendable CKRecord across the boundary.
        let records = mirror.records
        let sysFields = systemFields

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            let name = recordID.recordName
            guard let rec = records[name] else {
                // The entity disappeared locally before upload — drop the pending save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let base = Self.cachedRecord(from: sysFields[name])
                ?? CKRecord(recordType: CloudSyncSchema.recordType, recordID: recordID)
            rec.populate(base)
            return base
        }
    }

    // MARK: Event handlers

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        // LOCAL-FIRST: never delete local config on an Apple ID change. The
        // household roster lives in the user-independent Keychain and belongs to
        // the device, not to any single iCloud account (Apple's "family shares an
        // Apple TV + a service account" model). We only re-point the mirror at the
        // now-current Apple ID's private DB.
        switch event.changeType {
        case .signIn, .switchAccounts:
            // Fresh DB context: forget what the PREVIOUS account's DB held so we
            // don't assume records exist there, then re-derive + re-upload the
            // still-present local roster into the new account's DB.
            mirror = CloudSyncMirror()
            systemFields = [:]
            persist()
            await publishLocalChanges()
        case .signOut:
            // Stop mirroring; keep every bit of local config intact.
            mirror = CloudSyncMirror()
            systemFields = [:]
            persist()
            setStatus(.signedOut)
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        // Raw counts BEFORE decode: distinguishes "server delivered nothing" (mods=0
        // ⇒ send-side or token problem) from "delivered but we dropped it" (mods>0
        // but decoded 0 ⇒ decode bug).
        PlozzLog.sync.info("CloudSync: FETCH raw mods=\(event.modifications.count) dels=\(event.deletions.count)")
        var incoming: [CloudSyncRecord] = []
        for mod in event.modifications {
            let record = mod.record
            if let rec = CloudSyncRecord(ckRecord: record) {
                incoming.append(rec)
                systemFields[record.recordID.recordName] = Self.archive(record)
            } else {
                PlozzLog.sync.error("CloudSync: FETCH decode FAILED for \(record.recordID.recordName)")
            }
        }
        var deletedNames: [String] = []
        for del in event.deletions {
            deletedNames.append(del.recordID.recordName)
            systemFields[del.recordID.recordName] = nil
        }

        guard !incoming.isEmpty || !deletedNames.isEmpty else { return }
        let inDesc = incoming.map { "\($0.recordName)@\($0.editedAt)" }.joined(separator: ",")
        PlozzLog.sync.info("CloudSync: FETCHED \(incoming.count) [\(inDesc)] del=\(deletedNames.count)")
        let result = mirror.applyRemote(saved: incoming, deletedRecordNames: deletedNames)
        PlozzLog.sync.info("CloudSync: applyRemote changed=\(result.changed) toPush=\(result.toPush.count)")
        // Re-push any records where THIS device's copy beat the server's (server is
        // stale) so the fleet converges to the newer value.
        if !result.toPush.isEmpty {
            let pushes = result.toPush.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudSyncSchema.recordID(forRecordName: $0.recordName)) }
            engine?.state.add(pendingRecordZoneChanges: pushes)
        }
        persist()
        guard result.changed else { return }
        reportRecordCount()
        // Hand the merged, non-secret snapshot to the app to reconcile into its
        // stores (config-only; never signs a device in).
        await config.applyRemoteSnapshot(result.snapshot)
        PlozzLog.sync.info("CloudSync: applied \(incoming.count) fetched change(s), \(deletedNames.count) deletion(s)")
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        let sentDesc = event.savedRecords.map { $0.recordID.recordName }.joined(separator: ",")
        PlozzLog.sync.info("CloudSync: SENT ok=\(event.savedRecords.count) [\(sentDesc)] failed=\(event.failedRecordSaves.count)")
        for saved in event.savedRecords {
            systemFields[saved.recordID.recordName] = Self.archive(saved)
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zoneRetry: [CKSyncEngine.PendingDatabaseChange] = []

        for failure in event.failedRecordSaves {
            let record = failure.record
            let name = record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Conflict: the record already exists on the server with a change
                // tag we don't hold. ALWAYS cache the server's system fields first
                // (even if our payload decode fails) so the next save carries the
                // correct tag — otherwise we conflict forever.
                guard let serverRecord = failure.error.serverRecord else {
                    // No server record to reconcile against — drop the pending save
                    // to break the loop; a later fetch will re-seed it.
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                    continue
                }
                systemFields[name] = Self.archive(serverRecord)
                guard let serverRec = CloudSyncRecord(ckRecord: serverRecord) else { continue }
                let result = mirror.applyRemote(saved: [serverRec], deletedRecordNames: [])
                // With last-writer-wins by HLC timestamp, applyRemote already merged
                // the server's copy and advanced our clock past it. If OUR copy won
                // (server is stale), re-save it — it now carries a strictly-later
                // editedAt, so the save lands instead of looping. If the server won,
                // stop re-sending.
                if result.toPush.contains(where: { $0.recordName == name }) {
                    retry.append(.saveRecord(record.recordID))
                } else {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
                if result.changed {
                    Task { await self.config.applyRemoteSnapshot(result.snapshot) }
                }
            case .zoneNotFound:
                zoneRetry.append(.saveZone(CKRecordZone(zoneID: record.recordID.zoneID)))
                retry.append(.saveRecord(record.recordID))
                systemFields[name] = nil
            case .unknownItem:
                // Server lost the record but we still have it locally — re-upload.
                retry.append(.saveRecord(record.recordID))
                systemFields[name] = nil
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled:
                PlozzLog.sync.info("CloudSync: retryable save error for \(name): \(Self.ckCodeName(failure.error))")
            default:
                // The real cause of a 'failed to send changes' — surface it verbatim
                // (code + description + any per-item detail) so it's diagnosable.
                setDiagnostic("save failed for \(name): \(Self.ckCodeName(failure.error)) — \(failure.error.localizedDescription)")
            }
        }

        if !zoneRetry.isEmpty { syncEngine.state.add(pendingDatabaseChanges: zoneRetry) }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        persist()
    }

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        // Our zone was deleted on the server (e.g. another device opted out or
        // reset). Clear the mirror so we re-derive from local on the next publish;
        // local config is untouched.
        for deletion in event.deletions where deletion.zoneID.zoneName == CloudSyncSchema.zoneName {
            mirror = CloudSyncMirror()
            systemFields = [:]
            persist()
        }
    }

    // MARK: CKRecord system-field caching

    static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func cachedRecord(from data: Data?) -> CKRecord? {
        guard let data else { return nil }
        // A record archived with `encodeSystemFields(with:)` MUST be read back with
        // `CKRecord(coder:)` — NOT `unarchivedObject(ofClass:)`, which returns nil
        // for this encoding. Getting this wrong means the cached change tag is never
        // applied, so every save is a blind create that the server rejects with
        // serverRecordChanged — forever. That was the whole-sync-blocking bug.
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}
