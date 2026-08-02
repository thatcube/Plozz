import Foundation
import CloudKit
import CoreModels
import CoreNetworking

// MARK: - CloudConfigSyncService
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
//
// MULTIPLEXING: Apple permits exactly ONE active `CKSyncEngine` per private
// database. This actor owns that single engine and fans it out across multiple
// independent CHANNELS (a schema + its own `SyncLedger`), one per synced zone —
// currently Config V3 (the `Configuration` passed to `init`, kept as the primary
// channel for state-file/API compatibility) and, optionally, additional channels
// such as `PlozzMediaStateV1` (see `ChannelConfiguration`). Every CloudKit entry
// point (zone creation, queued changes, batch building, fetched records/deletions,
// send outcomes, zone deletions, inventory checks, full resync, delete-all/reset,
// account changes) routes each record/event to the channel whose schema matches
// its zone, so the channels' ledgers, state files, and app callbacks stay fully
// disjoint even though they share one engine, one container, and one delegate.
public actor CloudConfigSyncService {

    // MARK: Dependencies

    /// The PRIMARY channel's configuration. Kept API-compatible with the
    /// single-channel service: `schema` defaults to Config V3, and `stateFileURL`
    /// still encodes `{ledger, engineState}` exactly as before (engine state has
    /// nowhere else to live, and only one engine exists). Additional, fully
    /// independent channels are supplied via `init(_:channels:)`.
    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var schema: CloudSyncSchemaDescriptor
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
            schema: CloudSyncSchemaDescriptor = .configV3,
            isEnabled: @escaping @Sendable () -> Bool,
            captureRecords: @escaping @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data],
            applyRecords: @escaping @Sendable (SyncLocalChanges) async -> Void,
            onAccountSwitch: @escaping @Sendable () async -> Void = {},
            isHydrated: @escaping @Sendable () -> Bool = { true },
            status: CloudSyncStatus? = nil
        ) {
            self.containerIdentifier = containerIdentifier
            self.stateFileURL = stateFileURL
            self.schema = schema
            self.isEnabled = isEnabled
            self.captureRecords = captureRecords
            self.applyRecords = applyRecords
            self.onAccountSwitch = onAccountSwitch
            self.isHydrated = isHydrated
            self.status = status
        }
    }

    /// An ADDITIONAL, fully independent sync channel multiplexed onto the same
    /// engine/container as the primary `Configuration` — its own schema (own
    /// zone + record type), its own ledger persisted at its own `stateFileURL`
    /// (bare `SyncLedger` JSON; no engine state — there is only one engine, and its
    /// state already lives under the primary channel's file), and its own
    /// capture/apply/onAccountSwitch/isHydrated closures. There is no per-channel
    /// `isEnabled`: enablement is a single device-wide flag owned by the primary
    /// `Configuration`, shared by every channel this service multiplexes.
    public struct ChannelConfiguration: Sendable {
        public var schema: CloudSyncSchemaDescriptor
        public var stateFileURL: URL
        public var captureRecords: @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data]
        public var applyRecords: @Sendable (SyncLocalChanges) async -> Void
        public var onAccountSwitch: @Sendable () async -> Void
        public var isHydrated: @Sendable () -> Bool

        public init(
            schema: CloudSyncSchemaDescriptor,
            stateFileURL: URL,
            captureRecords: @escaping @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data],
            applyRecords: @escaping @Sendable (SyncLocalChanges) async -> Void,
            onAccountSwitch: @escaping @Sendable () async -> Void = {},
            isHydrated: @escaping @Sendable () -> Bool = { true }
        ) {
            self.schema = schema
            self.stateFileURL = stateFileURL
            self.captureRecords = captureRecords
            self.applyRecords = applyRecords
            self.onAccountSwitch = onAccountSwitch
            self.isHydrated = isHydrated
        }
    }

    /// One multiplexed sync channel: a schema, its own ledger, its own state file,
    /// and its own app-facing closures. A plain (non-Sendable) reference type held
    /// ONLY inside this actor's isolated storage — actor isolation is exactly what
    /// makes that safe, the same way the actor's own `var ledger` used to be safe
    /// pre-multiplexing.
    private final class Channel {
        let isPrimary: Bool
        let schema: CloudSyncSchemaDescriptor
        let stateFileURL: URL
        let captureRecords: @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data]
        let applyRecords: @Sendable (SyncLocalChanges) async -> Void
        let onAccountSwitch: @Sendable () async -> Void
        let isHydrated: @Sendable () -> Bool
        var ledger: SyncLedger

        init(
            isPrimary: Bool,
            schema: CloudSyncSchemaDescriptor,
            stateFileURL: URL,
            captureRecords: @escaping @Sendable (_ fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data],
            applyRecords: @escaping @Sendable (SyncLocalChanges) async -> Void,
            onAccountSwitch: @escaping @Sendable () async -> Void,
            isHydrated: @escaping @Sendable () -> Bool,
            ledger: SyncLedger
        ) {
            self.isPrimary = isPrimary
            self.schema = schema
            self.stateFileURL = stateFileURL
            self.captureRecords = captureRecords
            self.applyRecords = applyRecords
            self.onAccountSwitch = onAccountSwitch
            self.isHydrated = isHydrated
            self.ledger = ledger
        }
    }

    private let config: Configuration
    public nonisolated let schema: CloudSyncSchemaDescriptor
    public nonisolated let stateFileURL: URL
    /// Every multiplexed channel's schema (primary first, then additional channels
    /// in the order passed to `init`), exposed for tests/diagnostics that want to
    /// assert the disjoint schema set without constructing CloudKit.
    public nonisolated let channelSchemas: [CloudSyncSchemaDescriptor]
    /// Parallel to `channelSchemas`: each channel's own ledger state file path.
    public nonisolated let channelStateFileURLs: [URL]

    /// All multiplexed channels, primary first. Built once in `init`; the channel
    /// LIST never changes (only each channel's mutable `ledger`), so this is a
    /// `let`.
    private let channels: [Channel]

    /// Built lazily so merely CONSTRUCTING the service can't touch CloudKit.
    /// `CKContainer(identifier:)` traps (SIGTRAP) in any process whose entitlements
    /// don't carry that container — which is every unit-test host. It used to be
    /// built in `init`, so a test that reached `AppState.bootstrap()` killed the
    /// whole xctest process, and the remaining tests in the bundle silently never
    /// ran (the suite still reported "Executed 0 tests, with 0 failures").
    private lazy var container: CKContainer = CKContainer(identifier: config.containerIdentifier)

    /// Whether THIS build is actually entitled to the configured CloudKit container.
    ///
    /// `CKContainer(identifier:)` does not fail politely when the entitlement is
    /// missing — it traps with SIGTRAP, taking the app down before any `do/catch`
    /// or `accountStatus()` check can run. Making `container` lazy (above) keeps
    /// mere construction safe, but anything that *touches* it still dies, so this
    /// has to be checked before first use rather than recovered from.
    ///
    /// The case that motivated it: per-branch dev builds (`deploy-*.sh --branded`)
    /// sign against stripped entitlements, because a fresh per-branch App ID cannot
    /// auto-provision iCloud. Those builds crashed on launch the moment
    /// `startCloudSyncIfEnabled` reached `activate()`. They should just run without
    /// cloud sync.
    ///
    /// `SecTaskCopyValueForEntitlement` is macOS-only, so on iOS/tvOS we read the
    /// entitlements out of the embedded provisioning profile instead. When there is
    /// no profile to read we assume we ARE entitled: that is the conservative
    /// direction, since sync is only switched off when the absence can be positively
    /// proven, and a real user's build is never disabled by a parsing failure.
    private static let hasCloudKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return true }

        // The profile is CMS-signed; the payload is a plain plist embedded between
        // these markers. Scanning for them avoids pulling in a CMS decoder for what
        // is a one-shot launch check.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any]
        else { return true }

        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        return containers?.isEmpty == false
    }()
    private var engine: CKSyncEngine?
    /// Bumped every time the engine is rebuilt; events from an older engine are
    /// ignored (generation fencing).
    private var engineGeneration = 0
    /// Set after an iCloud account SWITCH: blocks publishing until we've successfully
    /// fetched the new account's real state, so this device never uploads the previous
    /// household's config into a different Apple ID before learning what's there.
    /// SHARED across every channel: there is one engine, one fetch, one account.
    private var suspendPublishUntilFetch = false
    /// True once this process has CONFIRMED the current account's server state (a
    /// successful fetch or real fetched data). Until then a device with no local
    /// baseline must not publish — stamping fresh edits over unknown server data would
    /// clobber peers. Gates EVERY normal publish path (S1), not just activate. SHARED
    /// across every channel (see `suspendPublishUntilFetch`).
    private var didConfirmServerState = false
    /// True for the duration of a full resync. Publishing while `beginFullResync` has
    /// cleared the baselines would re-mark everything dirty and resurrect peer
    /// deletions, so all publishing is deferred until the resync ends/aborts (S3).
    /// SHARED: a token reset rebuilds the ONE engine, so every channel's zone is
    /// re-fetched from scratch together.
    private var isFullResyncing = false
    /// False after `deactivate()`; true again after the next `activate()`. Fences
    /// every public entry point AND every delegate callback, so a disabled service
    /// can neither publish nor process CloudKit events even if a stale `engine`
    /// reference is still briefly alive.
    private var isActive = true

    // Persisted across launches. Only the PRIMARY channel's engine state is kept
    // here — additional channels persist only their own ledger (see `Channel`).
    private var engineState: CKSyncEngine.State.Serialization?

    public init(_ configuration: Configuration, channels extraChannels: [ChannelConfiguration] = []) {
        self.config = configuration
        self.schema = configuration.schema
        self.stateFileURL = configuration.stateFileURL

        let loadedPrimary = Self.loadPersisted(from: configuration.stateFileURL)
        let primary = Channel(
            isPrimary: true,
            schema: configuration.schema,
            stateFileURL: configuration.stateFileURL,
            captureRecords: configuration.captureRecords,
            applyRecords: configuration.applyRecords,
            onAccountSwitch: configuration.onAccountSwitch,
            isHydrated: configuration.isHydrated,
            ledger: loadedPrimary?.ledger ?? SyncLedger()
        )
        self.engineState = loadedPrimary?.engineState

        var built: [Channel] = [primary]
        for extra in extraChannels {
            built.append(Channel(
                isPrimary: false,
                schema: extra.schema,
                stateFileURL: extra.stateFileURL,
                captureRecords: extra.captureRecords,
                applyRecords: extra.applyRecords,
                onAccountSwitch: extra.onAccountSwitch,
                isHydrated: extra.isHydrated,
                ledger: Self.loadLedger(from: extra.stateFileURL) ?? SyncLedger()
            ))
        }
        self.channels = built
        self.channelSchemas = built.map(\.schema)
        self.channelStateFileURLs = built.map(\.stateFileURL)
        precondition(
            Set(built.map(\.schema.zoneName)).count == built.count,
            "Cloud sync channels must use distinct zones"
        )
        precondition(
            Set(built.map { $0.stateFileURL.standardizedFileURL }).count
                == built.count,
            "Cloud sync channels must use distinct state files"
        )
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

    /// Synced count is the TOTAL across every multiplexed channel, so it still
    /// reads as "how many records this device mirrors from iCloud" overall.
    private func reportRecordCount() {
        guard let status = config.status else { return }
        let total = channels.reduce(0) { $0 + $1.ledger.count }
        Task { @MainActor in status.syncedRecordCount = total }
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

    /// Bring the engine up (if enabled + an account is available), ensure every
    /// channel's zone, FETCH the server's real state FIRST (so a fresh/behind
    /// device learns the truth before it can publish stale local data over a
    /// peer), then publish genuine local diffs for every channel. Safe to call
    /// repeatedly. Re-arms the service if a prior `deactivate()` had fenced it.
    public func activate() async {
        isActive = true
        guard config.isEnabled() else {
            deactivate()
            return
        }
        // Reported as `disabled` rather than `signedOut`: the user has not signed
        // out of anything, this build simply cannot do cloud sync at all.
        guard Self.hasCloudKitEntitlement else {
            PlozzLog.sync.info("CloudSync: disabled — this build carries no iCloud entitlement")
            setStatus(.disabled)
            return
        }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        setStatus(.idle)
        await logAccountIdentity()
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: channels.map { .saveZone(CKRecordZone(zoneID: $0.schema.zoneID)) })
        for channel in channels { await cleanupLegacyZonesIfNeeded(for: channel) }
        // Fetch before publish — the anti-clobber ordering.
        do { try await fetchChangesDetached(engine); markServerStateConfirmed() }
        catch { setDiagnostic("activate fetch: \(Self.describe(error))") }
        // publishLocalChanges enforces the suspend / baseline / resync gates itself, so
        // a fresh device whose fetch failed simply no-ops instead of clobbering.
        await publishLocalChanges()
        reportRecordCount()
        await reconcileServerInventoryIfDue()
    }

    /// Fences and drops the engine, and blocks every publish/delegate path, so a
    /// disabled service can neither send nor receive. Non-destructive: every
    /// channel's ledger + state file are left exactly as they are, so a later
    /// `activate()` picks back up without re-seeding or re-fetching from scratch.
    public func deactivate() {
        guard isActive || engine != nil else { return }
        isActive = false
        engineGeneration += 1   // fence any in-flight delegate calls tied to the old engine
        engine = nil
        setStatus(.disabled)
        PlozzLog.sync.info("CloudSync: deactivated")
    }

    /// One-time: delete only the legacy CloudKit zones named by this channel's
    /// descriptor. Their stale records otherwise add fetch noise and inflate item
    /// counts. Idempotent and guarded by a persisted flag so it runs at most once
    /// per install; a failure just retries next launch. A channel with no legacy
    /// zones does no cleanup.
    private func cleanupLegacyZonesIfNeeded(for channel: Channel) async {
        guard !channel.schema.legacyZoneNames.isEmpty else { return }
        let key = channel.schema.userDefaultsKey(
            prefix: "com.plozz.cloudSync.didCleanupLegacyZones",
            containerIdentifier: config.containerIdentifier
        )
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [], deleting: channel.schema.legacyZoneIDs)
            UserDefaults.standard.set(true, forKey: key)
            PlozzLog.sync.info("CloudSync: deleted legacy zones \(channel.schema.legacyZoneNames.joined(separator: ", "))")
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
    /// publish genuine local diffs (for every channel) and send — the anti-clobber
    /// ordering.
    public func fetchNow() async {
        guard config.isEnabled() else {
            deactivate()
            return
        }
        guard isActive, await accountIsAvailable() else { return }
        ensureEngine()
        guard let engine else { return }
        if (try? await fetchChangesDetached(engine)) != nil { markServerStateConfirmed() }
        await publishLocalChanges()
        guard isActive, engine === self.engine else { return }
        try? await sendChangesDetached(engine)
        reportRecordCount()
    }

    /// Manual "Sync Now": fetch → publish (every channel) → send.
    public func syncNow() async {
        guard isActive else { return }
        guard config.isEnabled() else {
            deactivate()
            return
        }
        guard await accountIsAvailable() else { setStatus(.signedOut); return }
        ensureEngine()
        guard let engine else { return }
        setStatus(.syncing)
        var syncError: Error?
        do { try await fetchChangesDetached(engine); markServerStateConfirmed() }
        catch { syncError = error }
        await publishLocalChanges()
        guard isActive, engine === self.engine else { return }
        do { try await sendChangesDetached(engine) } catch {
            if syncError == nil { syncError = error }
        }
        reportRecordCount()
        if let syncError {
            setDiagnostic("sync: \(Self.describe(syncError))")
            setStatus(.error, error: (syncError as NSError).localizedDescription)
        } else {
            setStatus(.idle, syncedNow: true)
        }
    }

    static func describe(_ error: Error) -> String {  // l10n:content — developer-facing CloudKit diagnostic (NSError domain/code dump), logged only
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
    /// save/delete plan — for EVERY multiplexed channel. No-op when disabled or
    /// unchanged.
    ///
    /// `bypassBaselineGate` is set ONLY by reset/reseed, which has just made the
    /// server state known (it deleted all records), so publishing local as fresh
    /// creates is deliberate and safe.
    public func publishLocalChanges(bypassBaselineGate: Bool = false) async {
        guard isActive, config.isEnabled(), let engine else { return }
        for channel in channels {
            await publish(channel, engine: engine, bypassBaselineGate: bypassBaselineGate)
        }
    }

    /// Publish ONE channel's local diffs. Every safety rule below is evaluated
    /// per-channel EXCEPT the three SHARED gates (`suspendPublishUntilFetch`,
    /// `isFullResyncing`, `didConfirmServerState`) — see their declarations for why
    /// they're shared rather than per-channel.
    private func publish(_ channel: Channel, engine: CKSyncEngine, bypassBaselineGate: Bool) async {
        guard !suspendPublishUntilFetch else {
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: publish skipped — suspended pending account-switch fetch")
            return
        }
        // S3: never publish while a full resync has the baselines cleared — it would
        // re-mark everything dirty and resurrect peer deletions.
        guard !isFullResyncing else {
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: publish skipped — full resync in progress")
            return
        }
        // S1: a device that hasn't confirmed the current account's server state AND
        // has no local baseline for THIS channel must not publish — fresh-stamped
        // creates would clobber unknown remote data. (activate/fetchNow/syncNow set
        // didConfirmServerState on a successful fetch; real fetched data sets it too.)
        guard bypassBaselineGate || didConfirmServerState || channel.ledger.hasServerBaseline else {
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: publish deferred — server state not yet confirmed on a baseline-less device")
            return
        }
        // C2 (reentrancy anti-clobber): `captureRecords` awaits a hop to the app's
        // @MainActor, suspending this actor. A queued fetched-changes apply can run in
        // that window and advance THIS channel's ledger server baseline (and the
        // app's stores). If we then reconciled the PRE-apply snapshot, a stale local
        // value would be re-stamped newer and clobber the peer edit that just landed.
        // So we re-capture until no remote-driven mutation interleaved with the
        // capture, checked against THIS channel's own `remoteRevision`; reconcile is
        // synchronous and therefore atomic once we have a clean snapshot.
        var desired: [SyncRecordID: Data] = [:]
        var stabilized = false
        for _ in 0..<4 {
            let rev = channel.ledger.remoteRevision
            desired = await channel.captureRecords(channel.ledger.syncedValues())
            if channel.ledger.remoteRevision == rev { stabilized = true; break }
        }
        // S4: if a remote apply kept interleaving every capture, the snapshot may
        // predate the latest baseline. Do NOT reconcile an unverified capture (it could
        // clobber the just-arrived change) — skip this publish; a later one retries.
        guard stabilized else {
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: publish deferred — capture kept racing remote applies; will retry")
            return
        }
        let plan = channel.ledger.reconcileLocal(
            desired: desired, now: nowMillis(), synthesizeDeletions: channel.isHydrated())
        if !plan.refusedDeletions.isEmpty {
            setDiagnostic("refused \(plan.refusedDeletions.count) deletion(s) in \(channel.schema.zoneName) — capture looked incomplete; not wiping peers")
        }
        guard !plan.isEmpty else {
            persist()
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: publish — nothing changed")
            return
        }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for up in plan.uploads { pending.append(.saveRecord(channel.schema.recordID(forRecordName: up.recordName))) }
        for name in plan.deletes { pending.append(.deleteRecord(channel.schema.recordID(forRecordName: name))) }
        engine.state.add(pendingRecordZoneChanges: pending)
        persist()
        reportRecordCount()
        PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: queued \(plan.uploads.count) save(s), \(plan.deletes.count) delete(s)")
    }

    /// Publish and immediately send is intentionally NOT used — forcing sendChanges
    /// from the debounce raced CKSyncEngine's own scheduler and crashed on-device.
    /// `automaticallySync` sends queued changes; `syncNow`/`fetchNow` force it.

    /// Opt-out: erase this app's synced config from iCloud but KEEP the zones, so
    /// peers receive normal record deletions (never a zone-delete that strands
    /// their tokens). Covers EVERY multiplexed channel.
    public func deleteAllServerData() async {
        guard isActive, let engine else { return }
        for channel in channels {
            let names = channel.ledger.entries.keys
            guard !names.isEmpty else { continue }
            var pending: [CKSyncEngine.PendingRecordZoneChange] = []
            for name in names { pending.append(.deleteRecord(channel.schema.recordID(forRecordName: name))) }
            engine.state.add(pendingRecordZoneChanges: pending)
        }
        guard isActive, engine === self.engine else { return }
        try? await sendChangesDetached(engine)
        guard isActive, engine === self.engine else { return }
        for channel in channels { channel.ledger = SyncLedger() }
        persist()
    }

    /// Erase this app's synced config from iCloud and RE-SEED it from THIS device's
    /// current local config — the "Reset Synced Data" action. Deletes records (keeps
    /// the zones so peers get normal deletions), clears every channel's ledger, then
    /// republishes local as fresh creates. Local config is never touched.
    public func resetAndReseed() async {
        guard isActive, config.isEnabled(), await accountIsAvailable() else { return }
        setStatus(.syncing)
        await deleteAllServerData()   // deletes records + clears every channel's ledger
        guard isActive else { return }
        rebuildEngine()
        // Server state is known (just emptied), so bypass the baseline gate to re-seed.
        await publishLocalChanges(bypassBaselineGate: true)
        guard isActive else { return }
        do {
            if let engine { try await sendChangesDetached(engine) }
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: reset + reseeded from this device")
        } catch {
            setDiagnostic("reset: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    /// Repair a device stuck not-receiving: full-resync lifecycle. Resets ONLY the
    /// fetch token (keeps local values + dirty edits + pending deletes), re-fetches
    /// EVERY zone, and finalizes records a COMPLETE server snapshot no longer
    /// contains as deletions — so a peer's delete can never be resurrected in ANY
    /// channel. Non-destructive to the shared cloud data.
    ///
    /// This is engine-wide by necessity: `CKSyncEngine.State.Serialization` holds
    /// change tokens for every zone the engine tracks, so resetting it for one
    /// channel resets ALL of them — every channel's zone gets a complete re-fetch in
    /// lockstep, and each runs its own `beginFullResync`/`endFullResync` lifecycle
    /// against that shared re-fetch.
    public func redownloadFromCloud() async {
        guard isActive, config.isEnabled(), await accountIsAvailable() else { setStatus(.signedOut); return }
        setStatus(.syncing)
        PlozzLog.sync.info("CloudSync: redownload — full resync (keep local, reset token)")
        // S3: block all publishing while the baselines are cleared, so a concurrent
        // observation/manual publish can't re-mark everything dirty and resurrect
        // peer deletions. Lifted in every exit path below.
        isFullResyncing = true
        for channel in channels { channel.ledger.beginFullResync() }
        rebuildEngine(resetState: true)   // nil token ⇒ COMPLETE re-fetch; fences old events
        guard let engine else { isFullResyncing = false; setStatus(.error, error: "engine unavailable"); return }
        do {
            engine.state.add(pendingDatabaseChanges: channels.map { .saveZone(CKRecordZone(zoneID: $0.schema.zoneID)) })
            try await fetchChangesDetached(engine)
            guard isActive, engine === self.engine else {
                abortFullResync()
                return
            }
            markServerStateConfirmed()
            var confirmedDeletedByZone: [String: Set<SyncRecordID>] = [:]
            var finalizedByZone: [String: SyncLocalChanges] = [:]
            for channel in channels {
                // A fetch that omitted a record is NOT proof the record is gone: CloudKit
                // reads are eventually consistent, so a record a peer saved moments ago
                // can be missing from an otherwise-successful complete fetch. Ask the
                // server directly about each candidate before deleting anything. Records
                // that still exist are folded back in; only `unknownItem` counts as gone.
                let candidates = channel.ledger.resyncDeletionCandidates()
                var confirmedDeleted: Set<SyncRecordID> = []
                if !candidates.isEmpty {
                    let verdict = await verifyDeletionCandidates(candidates, schema: channel.schema)
                    guard isActive, engine === self.engine else {
                        abortFullResync()
                        return
                    }
                    confirmedDeleted = verdict.confirmedDeleted
                    if !verdict.stillPresent.isEmpty {
                        _ = channel.ledger.applyFetched(saved: verdict.stillPresent, deleted: [], now: nowMillis())
                        PlozzLog.sync.info(
                            "CloudSync[\(channel.schema.zoneName)]: redownload — \(verdict.stillPresent.count) record(s) missing from the fetch still exist on the server; kept"
                        )
                    }
                }
                confirmedDeletedByZone[channel.schema.zoneName] = confirmedDeleted
            }
            for channel in channels {
                finalizedByZone[channel.schema.zoneName] = channel.ledger
                    .endFullResync(
                        confirmedDeleted: confirmedDeletedByZone[
                            channel.schema.zoneName,
                            default: []
                        ]
                    )
            }
            isFullResyncing = false
            persist()
            reportRecordCount()
            for channel in channels {
                guard let finalized = finalizedByZone[channel.schema.zoneName],
                      !finalized.isEmpty else {
                    continue
                }
                let applyRecords = channel.applyRecords
                await outsideDelegateContext { await applyRecords(finalized) }
            }
            guard isActive, engine === self.engine else { return }
            // Requeue anything still dirty / pending-delete without re-stamping.
            var pending: [CKSyncEngine.PendingRecordZoneChange] = []
            for channel in channels {
                pending += channel.ledger.pendingUploads().map { .saveRecord(channel.schema.recordID(forRecordName: $0.recordName)) }
                pending += channel.ledger.pendingDeletes().map { .deleteRecord(channel.schema.recordID(forRecordName: $0)) }
            }
            if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: pending); try await sendChangesDetached(engine) }
            // Replay one publish for any genuine local edits made during the resync
            // (they were deferred by the isFullResyncing gate).
            await publishLocalChanges()
            let total = channels.reduce(0) { $0 + $1.ledger.count }
            setStatus(.idle, syncedNow: true)
            PlozzLog.sync.info("CloudSync: redownload complete — \(total) record(s)")
        } catch {
            // A FAILED / incomplete fetch must NOT be finalized as a full snapshot
            // (that would delete records the fetch simply didn't reach). Abort the
            // resync for EVERY channel WITHOUT producing any deletions; a later
            // successful fetch re-establishes the true baseline.
            for channel in channels { channel.ledger.abortFullResync() }
            isFullResyncing = false
            persist()
            setDiagnostic("redownload: \(Self.describe(error))")
            setStatus(.error, error: (error as NSError).localizedDescription)
        }
    }

    private func abortFullResync() {
        for channel in channels { channel.ledger.abortFullResync() }
        isFullResyncing = false
        persist()
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
    /// (INCLUDING every zone's change token) is discarded, so the next `fetchChanges`
    /// is a COMPLETE re-fetch of every zone rather than an incremental delta —
    /// required for a valid full resync (`redownloadFromCloud`). Otherwise the change
    /// token is preserved.
    private func rebuildEngine(resetState: Bool) {
        engineGeneration += 1
        if resetState { engineState = nil }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: engineState, delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        PlozzLog.sync.info("CloudSync: engine initialized (gen \(engineGeneration), resetState=\(resetState))")
    }

    // MARK: Engine entry points (CloudKit re-entrancy trap)
    //
    // CKSyncEngine TRAPS (SIGTRAP, not a throw) with
    //   "BUG IN CLIENT OF CLOUDKIT: Cannot await a call into CKSyncEngine from within
    //    a delegate callback … Try performing this in a detached Task."
    // whenever `fetchChanges`/`sendChanges` is reached from a task that carries the
    // task-local marker CloudKit sets for the duration of a delegate callback.
    //
    // That marker is INHERITED by every unstructured `Task { }` created while a
    // callback is on the stack — and this service creates a lot of them indirectly:
    // `handleEvent` awaits `channel.applyRecords`, which mutates the app's stores on
    // the MainActor, which fires Observation `onChange` handlers, which spawn tasks
    // (debounced publish, the rendezvous poll loop) that later call back in here.
    // None of those are structurally waiting on the callback — they merely inherited
    // its context — so the trap is a false alarm, but it still kills the app. Worse,
    // a long-lived task that inherits it once (the poll loop) poisons every fetch for
    // the rest of the session.
    //
    // `Task.detached` starts with NO inherited task-locals, which is exactly the
    // escape hatch CloudKit's own message prescribes. Routing every engine call
    // through here makes the trap unreachable no matter which path leaked the
    // context, and `.value` preserves the caller's ordering/awaiting semantics.
    private func fetchChangesDetached(_ engine: CKSyncEngine) async throws {
        try await Task.detached(priority: .userInitiated) { try await engine.fetchChanges() }.value
    }

    private func sendChangesDetached(_ engine: CKSyncEngine) async throws {
        try await Task.detached(priority: .userInitiated) { try await engine.sendChanges() }.value
    }

    /// Run an app-facing callback outside the delegate-callback context (see above),
    /// so tasks the app spawns while applying a change never inherit CloudKit's
    /// marker in the first place. Still awaited, so ordering is unchanged.
    private func outsideDelegateContext(_ body: @escaping @Sendable () async -> Void) async {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    private func accountIsAvailable() async -> Bool {
        // Checked here because every path that touches `container` — activate,
        // fetchNow, syncNow, resetAndReseed, redownloadFromCloud,
        // reconcileServerInventory — passes through this method first. Returning
        // false makes them all no-op instead of trapping. See
        // `hasCloudKitEntitlement`.
        guard Self.hasCloudKitEntitlement else { return false }
        do { return try await container.accountStatus() == .available }
        catch { PlozzLog.sync.error("CloudSync: accountStatus failed: \(error.localizedDescription)"); return false }
    }

    // MARK: Persistence

    /// The PRIMARY channel's on-disk shape. Unchanged since before multiplexing:
    /// `{ledger, engineState}`, decoded exactly the same way.
    private struct Persisted: Codable {
        var ledger: SyncLedger
        var engineState: CKSyncEngine.State.Serialization?
    }

    private static func loadPersisted(from url: URL) -> Persisted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    /// An additional channel's on-disk shape: just its `SyncLedger` — there is only
    /// one engine, so there is no second engine state to persist alongside it.
    private static func loadLedger(from url: URL) -> SyncLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let ledger = try? JSONDecoder().decode(SyncLedger.self, from: data) {
            return ledger
        }
        return try? JSONDecoder().decode(Persisted.self, from: data).ledger
    }

    /// Ask the server directly whether each candidate record still exists, for ONE
    /// channel's schema.
    ///
    /// `records(for:)` answers per-record, so a record that comes back is proof it is
    /// still there (the resync fetch simply hadn't converged), and only an explicit
    /// `unknownItem` is proof of deletion. Any OTHER error (network, throttle, auth)
    /// is inconclusive and deliberately counts as "not confirmed", so a transient
    /// failure can never destroy a record.
    private func verifyDeletionCandidates(
        _ names: [SyncRecordID], schema: CloudSyncSchemaDescriptor
    ) async -> (confirmedDeleted: Set<SyncRecordID>, stillPresent: [SyncRemoteRecord]) {
        var confirmed: Set<SyncRecordID> = []
        var present: [SyncRemoteRecord] = []
        let database = container.privateCloudDatabase
        // Chunked so a large candidate set can't exceed CloudKit's per-request limits.
        for chunk in stride(from: 0, to: names.count, by: 200).map({
            Array(names[$0..<min($0 + 200, names.count)])
        }) {
            let ids = chunk.map { schema.recordID(forRecordName: $0) }
            do {
                let results = try await database.records(for: ids)
                for (id, result) in results {
                    switch result {
                    case .success(let record):
                        if let decoded = SyncRemoteRecord(ckRecord: record, schema: schema) {
                            present.append(decoded)
                        }
                    case .failure(let error):
                        if let ckError = error as? CKError, ckError.code == .unknownItem {
                            confirmed.insert(id.recordName)
                        } else {
                            PlozzLog.sync.info(
                                "CloudSync: redownload — inconclusive existence check for \(id.recordName): \(Self.describe(error)); keeping"
                            )
                        }
                    }
                }
            } catch {
                // Whole-request failure proves nothing about any record in it.
                PlozzLog.sync.info(
                    "CloudSync: redownload — existence check failed for \(chunk.count) record(s): \(Self.describe(error)); keeping"
                )
            }
        }
        return (confirmed, present)
    }

    // MARK: Convergence check

    /// Minimum spacing between inventory reconciles. The check is cheap (record ids
    /// only) but it's a safety net, not a sync path — once a launch is plenty.
    private static let inventoryReconcileInterval: TimeInterval = 6 * 60 * 60

    private func reconcileServerInventoryIfDue() async {
        let key = "com.plozz.cloudSync.lastInventoryReconcile.\(config.containerIdentifier)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard last <= 0 || now - last >= Self.inventoryReconcileInterval else {
            // Say so rather than returning silently: otherwise "throttled" and
            // "never wired up" look identical in a device log.
            let mins = Int((Self.inventoryReconcileInterval - (now - last)) / 60)
            PlozzLog.sync.info("CloudSync: inventory check throttled (next in ~\(mins)m)")
            return
        }
        await reconcileServerInventory()
        UserDefaults.standard.set(now, forKey: key)
    }

    /// Detect and repair a device that is missing records the server has, in EVERY
    /// multiplexed channel/zone.
    ///
    /// The incremental change token can leave a device permanently behind: once it
    /// advances past a record the device never ledgered, nothing re-delivers it, and
    /// the gap is invisible — you'd only notice by comparing item counts across two
    /// devices by eye. This compares the server's full inventory against each
    /// channel's ledger and pulls back anything absent.
    ///
    /// STRICTLY ADDITIVE. It never deletes: a record present locally but not on the
    /// server is only logged. Inferring deletion from absence is precisely the bug
    /// that destroyed records here (see `endFullResync`), and a safety net must not
    /// be able to cause the harm it exists to catch.
    public func reconcileServerInventory() async {
        guard isActive, config.isEnabled(), await accountIsAvailable() else { return }
        for channel in channels {
            await reconcileServerInventory(for: channel)
        }
    }

    private func reconcileServerInventory(for channel: Channel) async {
        let database = container.privateCloudDatabase
        var serverNames: Set<SyncRecordID> = []
        var token: CKServerChangeToken?
        do {
            // A throwaway token walk (`since: nil`, ids only) — authoritative, and it
            // does NOT disturb the sync engine's own token.
            while true {
                let batch = try await database.recordZoneChanges(
                    inZoneWith: channel.schema.zoneID, since: token, desiredKeys: []
                )
                for (id, result) in batch.modificationResultsByID {
                    if case .success = result { serverNames.insert(id.recordName) }
                }
                token = batch.changeToken
                if !batch.moreComing { break }
            }
        } catch {
            PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: inventory check skipped — \(Self.describe(error))")
            return
        }

        let localNames = Set(channel.ledger.entries.keys)
        let missingLocally = serverNames.subtracting(localNames)
        let onlyLocal = localNames.subtracting(serverNames)

        // Always report the outcome, including the clean one. A check that only
        // speaks up when it finds something is indistinguishable from a check that
        // never ran — which is precisely how the original divergence stayed hidden.
        // `onlyLocal` is expected while an upload is in flight; it is never acted on.
        PlozzLog.sync.info(
            "CloudSync[\(channel.schema.zoneName)]: inventory — server=\(serverNames.count) local=\(localNames.count) "
                + "missingLocally=\(missingLocally.count) localOnly=\(onlyLocal.count)"
        )
        guard !missingLocally.isEmpty else { return }

        PlozzLog.sync.error("CloudSync[\(channel.schema.zoneName)]: inventory GAP — \(missingLocally.count) record(s) on the server are missing locally; repairing")
        let recovered = await fetchRecords(Array(missingLocally), schema: channel.schema)
        guard !recovered.isEmpty else {
            setDiagnostic("inventory gap of \(missingLocally.count) record(s) in \(channel.schema.zoneName) — could not fetch them")
            return
        }
        let changes = channel.ledger.applyFetched(saved: recovered, deleted: [], now: nowMillis())
        persist(); reportRecordCount()
        if !changes.isEmpty {
            let applyRecords = channel.applyRecords
            await outsideDelegateContext { await applyRecords(changes) }
        }
        PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: inventory repaired — recovered \(recovered.count) record(s)")
    }

    /// Fetch specific records by name for ONE channel's schema, skipping any that
    /// fail. Chunked for CloudKit's per-request limits.
    private func fetchRecords(_ names: [SyncRecordID], schema: CloudSyncSchemaDescriptor) async -> [SyncRemoteRecord] {
        var out: [SyncRemoteRecord] = []
        let database = container.privateCloudDatabase
        for start in stride(from: 0, to: names.count, by: 200) {
            let chunk = Array(names[start..<min(start + 200, names.count)])
            let ids = chunk.map { schema.recordID(forRecordName: $0) }
            do {
                for (_, result) in try await database.records(for: ids) {
                    if case .success(let record) = result,
                       let decoded = SyncRemoteRecord(ckRecord: record, schema: schema) {
                        out.append(decoded)
                    }
                }
            } catch {
                PlozzLog.sync.info("CloudSync[\(schema.zoneName)]: inventory fetch failed for \(chunk.count) record(s): \(Self.describe(error))")
            }
        }
        return out
    }

    /// Persist EVERY channel: the primary alongside `engineState` (compat format,
    /// `{ledger, engineState}`), every other channel as its own bare `SyncLedger`.
    private func persist() {
        for channel in channels {
            do {
                try FileManager.default.createDirectory(
                    at: channel.stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data: Data
                if channel.isPrimary {
                    data = try JSONEncoder().encode(Persisted(ledger: channel.ledger, engineState: engineState))
                } else {
                    data = try JSONEncoder().encode(channel.ledger)
                }
                try data.write(to: channel.stateFileURL, options: .atomic)
            } catch {
                PlozzLog.sync.error("CloudSync[\(channel.schema.zoneName)]: failed to persist state: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudConfigSyncService: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // Generation + activation fence: ignore events from a stale engine (post-
        // rebuild) or a deactivated service.
        guard isActive, syncEngine === engine else {
            PlozzLog.sync.info("CloudSync: ignoring event from a stale or deactivated engine")
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
        case .didFetchChanges:
            markServerStateConfirmed()
            setStatus(.idle, syncedNow: true)
        case .didSendChanges:
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
        // Generation + activation fence: a stale engine (kept alive by
        // automaticallySync after a rebuild) or a deactivated service must not
        // produce a batch — its saves would use stale tags/values and its
        // completion event is ignored, diverging cloud from ledger state.
        guard isActive, syncEngine === engine else {
            PlozzLog.sync.info("CloudSync: ignoring batch request from a stale or deactivated engine")
            return nil
        }
        let schemas = channels.map(\.schema)
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { change in
            guard scope.contains(change) else { return false }
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                // Unknown foreign zones (not one of ours) are never surfaced here.
                return schemas.contains { $0.contains(recordID) }
            @unknown default:
                return false
            }
        }
        // Snapshot each channel's (schema, entries) BEFORE the batch closure runs —
        // the closure itself must stay synchronous/Sendable, so it captures values,
        // not `self`.
        let entriesByZone: [String: (schema: CloudSyncSchemaDescriptor, entries: [SyncRecordID: SyncLedgerEntry])] =
            Dictionary(uniqueKeysWithValues: channels.map { ($0.schema.zoneName, ($0.schema, $0.ledger.entries)) })
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard let (schema, entries) = entriesByZone[recordID.zoneID.zoneName] else { return nil }
            let name = recordID.recordName
            guard let entry = entries[name], !entry.pendingDelete else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let cached = CloudSyncSystemFields.record(from: entry.systemFields)
            let base = cached.flatMap {
                schema.matches($0) && $0.recordID == recordID ? $0 : nil
            }
                ?? CKRecord(recordType: schema.recordType, recordID: recordID)
            SyncUpload(recordName: name, value: entry.localValue,
                       editedAt: entry.editedAt, systemFields: entry.systemFields)
                .populate(base, schema: schema)
            return base
        }
    }

    // MARK: Event handlers

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            // Fires on EVERY engine init for the SAME account too. Do NOTHING to any
            // channel's ledger and never republish — the persisted ledgers already
            // reflect the server, and the engine fetches/reconciles on its own.
            // (Wiping+republishing here was THE V2 clobber.)
            PlozzLog.sync.info("CloudSync: accountChange signIn — keeping ledgers, no republish")
        case .switchAccounts:
            // A different Apple ID ⇒ a different private DB. Forget server bookkeeping
            // for EVERY channel so we don't assume records exist there. CRITICAL: also
            // drop state DERIVED from the previous account (synced-but-not-signed-in
            // server descriptors, and any other channel's equivalent) and SUSPEND
            // publishing until we've fetched the new account — otherwise this device
            // would upload the previous household's config into the new Apple ID. This
            // device's OWN local config (signed-in accounts, profiles, local media
            // aliases) is kept; it legitimately belongs to the device.
            PlozzLog.sync.info("CloudSync: accountChange switchAccounts — clearing ledgers + remote-derived state, suspending publish")
            for channel in channels { channel.ledger = SyncLedger() }
            suspendPublishUntilFetch = true
            persist()
            for channel in channels {
                let onAccountSwitch = channel.onAccountSwitch
                await outsideDelegateContext { await onAccountSwitch() }
            }
        case .signOut:
            for channel in channels { channel.ledger = SyncLedger() }
            suspendPublishUntilFetch = true
            persist()
            setStatus(.signedOut)
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        let knownZoneNames = Set(channels.map { $0.schema.zoneName })
        for channel in channels {
            var incoming: [SyncRemoteRecord] = []
            for mod in event.modifications where mod.record.recordID.zoneID.zoneName == channel.schema.zoneName {
                if let rec = SyncRemoteRecord(ckRecord: mod.record, schema: channel.schema) {
                    incoming.append(rec)
                } else {
                    // Never silently drop: a rejected record is a real signal (old-schema or
                    // malformed). Logged, not consumed as data.
                    PlozzLog.sync.error("CloudSync: fetch ignored foreign/malformed record \(mod.record.recordID.recordName) type=\(mod.record.recordType) zone=\(mod.record.recordID.zoneID.zoneName)")
                }
            }
            var deletedNames: [SyncRecordID] = []
            for del in event.deletions where del.recordID.zoneID.zoneName == channel.schema.zoneName {
                deletedNames.append(del.recordID.recordName)
            }

            guard !incoming.isEmpty || !deletedNames.isEmpty else { continue }
            let changes = channel.ledger.applyFetched(saved: incoming, deleted: deletedNames, now: nowMillis())
            persist()
            reportRecordCount()
            if !changes.isEmpty {
                let applyRecords = channel.applyRecords
                await outsideDelegateContext { await applyRecords(changes) }
                PlozzLog.sync.info("CloudSync[\(channel.schema.zoneName)]: applied \(changes.count) change(s) from \(incoming.count) fetched, \(deletedNames.count) deleted")
            }
        }
        // A record/deletion whose zone matches none of our channels is a foreign
        // zone (never one we created) — log and ignore, never feed a ledger.
        for mod in event.modifications where !knownZoneNames.contains(mod.record.recordID.zoneID.zoneName) {
            PlozzLog.sync.error("CloudSync: fetch ignored record from unknown zone \(mod.record.recordID.zoneID.zoneName)")
        }
        for del in event.deletions where !knownZoneNames.contains(del.recordID.zoneID.zoneName) {
            PlozzLog.sync.error("CloudSync: fetch ignored deletion from unknown zone \(del.recordID.zoneID.zoneName)")
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine
    ) async {
        for channel in channels {
            let schema = channel.schema
            for saved in event.savedRecords where schema.matches(saved) {
                let value = (saved[schema.fieldValue] as? Data) ?? Data()
                let editedAt = schema.int64(saved[schema.fieldEditedAt]) ?? 0
                channel.ledger.applySendSuccess(recordName: saved.recordID.recordName, savedValue: value,
                                        savedEditedAt: editedAt, systemFields: CloudSyncSystemFields.archive(saved))
            }
            for id in event.deletedRecordIDs where schema.contains(id) {
                channel.ledger.applyDeleteSuccess(id.recordName)
            }

            var applied: SyncLocalChanges = [:]
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var zoneRetry: [CKSyncEngine.PendingDatabaseChange] = []

            for failure in event.failedRecordSaves {
                let record = failure.record
                guard schema.matches(record) else { continue }
                let name = record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    guard let serverRecord = failure.error.serverRecord,
                          let rec = SyncRemoteRecord(ckRecord: serverRecord, schema: schema) else {
                        // The server reported a conflict but we can't read/decode its
                        // record (nil serverRecord, or an older/foreign schema). DON'T drop
                        // the local edit — clear the stale tag and retry so a subsequent
                        // fetch+reconcile resolves it. Silently removing the pending change
                        // would permanently lose this device's edit.
                        channel.ledger.clearServerRecord(name)
                        retry.append(.saveRecord(record.recordID))
                        setDiagnostic("serverRecordChanged without a decodable serverRecord for \(name) — retrying")
                        continue
                    }
                    if let (rn, val) = channel.ledger.applySendConflict(rec, now: nowMillis()) {
                        applied.updateValue(val, forKey: rn)   // server won → apply its value
                    } else {
                        retry.append(.saveRecord(record.recordID))  // we won → retry with fresh tag
                    }
                case .zoneNotFound:
                    zoneRetry.append(.saveZone(CKRecordZone(zoneID: record.recordID.zoneID)))
                    channel.ledger.clearServerRecord(name)
                    retry.append(.saveRecord(record.recordID))
                case .unknownItem:
                    // The record we tried to update doesn't exist — re-create (config policy).
                    channel.ledger.clearServerRecord(name)
                    retry.append(.saveRecord(record.recordID))
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                     .notAuthenticated, .operationCancelled:
                    PlozzLog.sync.info("CloudSync: retryable save error for \(name): \(Self.ckCodeName(failure.error))")
                default:
                    setDiagnostic("save failed for \(name): \(Self.ckCodeName(failure.error))")
                }
            }

            for (id, error) in event.failedRecordDeletes where schema.contains(id) {
                if error.code == .unknownItem { channel.ledger.applyDeleteSuccess(id.recordName) }  // already gone
                else { retry.append(.deleteRecord(id)) }
            }

            if !zoneRetry.isEmpty { syncEngine.state.add(pendingDatabaseChanges: zoneRetry) }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            persist()
            reportRecordCount()
            if !applied.isEmpty {
                let applyRecords = channel.applyRecords
                let changesToApply = applied
                await outsideDelegateContext {
                    await applyRecords(changesToApply)
                }
            }
        }
    }

    private func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        // A zone was deleted on the server (a peer opted out / reset). Clear ONLY
        // that channel's ledger so it re-derives from local on the next publish;
        // local state is untouched. We never delete a zone ourselves, so this is
        // rare. A deletion naming a zone that matches none of our channels is a
        // foreign zone — ignored, never fed to a ledger.
        let knownZoneNames = Set(channels.map { $0.schema.zoneName })
        var didClear = false
        for deletion in event.deletions {
            guard let channel = channels.first(where: { $0.schema.zoneName == deletion.zoneID.zoneName }) else {
                if !knownZoneNames.contains(deletion.zoneID.zoneName) {
                    PlozzLog.sync.info("CloudSync: ignoring zone deletion for unknown zone \(deletion.zoneID.zoneName)")
                }
                continue
            }
            channel.ledger = SyncLedger()
            didClear = true
        }
        if didClear { persist() }
    }
}
