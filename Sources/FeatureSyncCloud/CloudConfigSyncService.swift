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
            status.phase = phase
            if syncedNow { status.lastSyncedAt = Date(); status.lastDiagnostic = nil }
            status.lastErrorMessage = error
        }
    }

    /// Record a PERSISTENT diagnostic detail (survives the phase flicker).
    private func setDiagnostic(_ detail: String) {
        PlozzLog.sync.error("CloudSync: \(detail)")
        guard let status = config.status else { return }
        Task { @MainActor in status.lastDiagnostic = detail }
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
    }

    /// Force an immediate two-way sync (fetch then send), for a manual "Sync Now".
    public func syncNow() async {
        guard config.isEnabled() else { setStatus(.disabled); return }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        guard let engine else { return }
        setStatus(.syncing)
        do {
            await publishLocalChanges()
            try await engine.fetchChanges()
            try await engine.sendChanges()
            setStatus(.idle, syncedNow: true)
        } catch {
            PlozzLog.sync.error("CloudSync: manual sync failed: \(error.localizedDescription)")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
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
        PlozzLog.sync.info("CloudSync: queued \(plan.saves.count) save(s), \(plan.deletes.count) delete(s)")
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
        var incoming: [CloudSyncRecord] = []
        for mod in event.modifications {
            let record = mod.record
            if let rec = CloudSyncRecord(ckRecord: record) {
                incoming.append(rec)
                systemFields[record.recordID.recordName] = Self.archive(record)
            }
        }
        var deletedNames: [String] = []
        for del in event.deletions {
            deletedNames.append(del.recordID.recordName)
            systemFields[del.recordID.recordName] = nil
        }

        guard !incoming.isEmpty || !deletedNames.isEmpty else { return }
        let result = mirror.applyRemote(saved: incoming, deletedRecordNames: deletedNames)
        persist()
        guard result.changed else { return }
        // Hand the merged, non-secret snapshot to the app to reconcile into its
        // stores (config-only; never signs a device in).
        await config.applyRemoteSnapshot(result.snapshot)
        PlozzLog.sync.info("CloudSync: applied \(incoming.count) fetched change(s), \(deletedNames.count) deletion(s)")
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
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
                // Conflict: merge the server's copy via the deterministic resolver.
                guard let serverRecord = failure.error.serverRecord,
                      let serverRec = CloudSyncRecord(ckRecord: serverRecord) else { continue }
                systemFields[name] = Self.archive(serverRecord)
                let result = mirror.applyRemote(saved: [serverRec], deletedRecordNames: [])
                // If OUR value still wins after merging, re-save it; else adopt server.
                if let localRec = mirror.records[name], localRec != serverRec {
                    retry.append(.saveRecord(record.recordID))
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

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func cachedRecord(from data: Data?) -> CKRecord? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }
}
