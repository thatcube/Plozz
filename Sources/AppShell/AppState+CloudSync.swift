import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureSyncSetup
import FeatureSyncCloud

// MARK: - CloudSyncUIModel
//
// Small @Observable facet holding the CloudKit "needs sign-in" server UI state,
// kept off AppState so AppState's tracked-mutable-property budget stays flat
// (per the architecture layering guard).
@MainActor
@Observable
public final class CloudSyncUIModel {
    /// Synced servers this device isn't signed into yet ("Needs sign-in").
    public internal(set) var pendingSyncedServers: [SyncedAccountDescriptor] = []
    /// A newly-detected synced server to prompt about (Set Up / Ignore), or nil.
    public var pendingServerPrompt: SyncedAccountDescriptor?
    /// A same-Apple-ID device asking to be set up (it opened its "set up from another
    /// device" screen). Drives a one-tap source-side confirm before this TV pushes its
    /// servers + logins over the local pairing channel. nil = no pending offer.
    public var pendingSyncSetupOffer: SyncPairingRendezvous?
    public init() {}
}

// MARK: - AppState + CloudKit config auto-sync
//
// Wires the pure/engine layers (CoreModels.CloudSyncMirror + FeatureSyncCloud) into
// the app. Two seams:
//   • `currentSyncConfigSnapshot()` — build the NON-SECRET snapshot to publish
//     (descriptors, profiles, per-profile settings + membership). NEVER tokens.
//   • `applyRemoteConfigSnapshot(_:)` — reconcile an incoming merged snapshot into
//     the app's stores, CONFIG-ONLY: it imports/updates the profile roster,
//     settings and membership, but never signs a device in and never touches the
//     Keychain (Apple-correct shared-roster model; credentials stay with pairing).
//
// Everything is gated on `SyncSetupFeatureFlag` (device-wide, OFF by default) and
// is idempotent + loop-safe: applying a remote change leaves the local state equal
// to the mirror, so the observation-driven re-publish it triggers is a no-op.
extension AppState {

    private static let cloudContainerIdentifier = "iCloud.com.thatcube.Plozz"

    /// A writable directory for the sync state, robust across platforms. Tries
    /// Application Support (iOS), then Caches (tvOS's reliably-writable area), then
    /// the temporary directory as a last resort — so `cloudSync` is never nil just
    /// because a preferred directory couldn't be created (the bug that left tvOS
    /// unable to activate sync at all).
    static func writableStateDirectory() -> URL? {
        let fm = FileManager.default
        for domain in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let url = try? fm.url(for: domain, in: .userDomainMask, appropriateFor: nil, create: true) {
                return url
            }
        }
        let tmp = fm.temporaryDirectory
        return (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil ? tmp : tmp
    }

    /// Build the service, capturing `self` weakly for the config/apply closures.
    /// The enabled-check reads the device-wide flag straight from `UserDefaults`
    /// (thread-safe) so it needs no main-actor hop. Returns `nil` only if no
    /// writable state location exists.
    static func makeCloudSync(for appState: AppState) -> CloudConfigSyncService? {
        // tvOS restricts persistent storage — .applicationSupportDirectory often
        // can't be created — so fall back to Caches (CKSyncEngine can rebuild its
        // state if it's ever purged). Per-Apple-TV-user (both dirs are partitioned
        // by the runs-as-current-user entitlement), so each system user's engine
        // state stays separate.
        guard let baseDir = Self.writableStateDirectory() else { return nil }
        let stateURL = baseDir
            .appendingPathComponent("PlozzSync", isDirectory: true)
            .appendingPathComponent("cloud-config-v3.json")

        return CloudConfigSyncService(.init(
            containerIdentifier: cloudContainerIdentifier,
            stateFileURL: stateURL,
            isEnabled: { SyncSetupFeatureFlag().isEnabled },
            captureRecords: { [weak appState] fallback in
                guard let appState else { return [:] }
                return await appState.captureSyncRecords(fallback: fallback)
            },
            applyRecords: { [weak appState] changes in
                await appState?.applySyncRecords(changes)
            },
            onAccountSwitch: { [weak appState] in
                await appState?.clearRemoteDerivedSyncState()
            },
            status: appState.cloudSyncStatus
        ))
    }

    /// Force an immediate two-way sync (manual "Sync Now").
    public func syncCloudNow() {
        guard let cloudSync else { return }
        Task { await cloudSync.syncNow() }
    }

    /// Lightweight pull when the app comes to the foreground, so config changed on
    /// another device appears promptly (tvOS push is unreliable).
    public func syncCloudOnForeground() {
        guard let cloudSync, SyncSetupFeatureFlag().isEnabled else { return }
        Task { await cloudSync.fetchNow() }
        checkForSyncSetupOffer()
        startSyncSetupOfferPolling()
    }

    // MARK: Same-Apple-ID rendezvous offer (source side)

    /// Surface a one-tap confirm when another of the user's devices is asking to be set
    /// up (it opened its "set up from another device" screen and published a rendezvous
    /// to iCloud). We never push credentials silently — the single confirm keeps a human
    /// in the loop (matching Apple's "set up new device" pattern) — but it's zero typing:
    /// no code, no QR. Mirrors the iOS source-side behavior so a TV can set up a phone.
    public func checkForSyncSetupOffer() {
        guard SyncSetupFeatureFlag().isEnabled,
              !isAutoAdoptingSyncSetup,
              cloudSyncUI.pendingSyncSetupOffer == nil else { return }
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        guard !localIDs.isEmpty else { return }   // nothing to give
        guard let offer = syncSetup.discoverRendezvousTargets().first(where: { offer in
            guard !dismissedSyncSetupOfferKeys.contains(Self.syncSetupOfferKey(offer)) else { return false }
            // A per-server request is only fulfillable if THIS device holds that
            // account; otherwise skip it (another device may be able to serve it).
            if let requested = offer.requestedAccountID { return localIDs.contains(requested) }
            return true
        }) else { return }
        cloudSyncUI.pendingSyncSetupOffer = offer
    }

    /// The user confirmed — push config + credentials to the offered device over the
    /// local pairing channel (pinned key ⇒ no SAS, no typing).
    public func confirmSyncSetupOffer() {
        guard let offer = cloudSyncUI.pendingSyncSetupOffer else { return }
        cloudSyncUI.pendingSyncSetupOffer = nil
        isAutoAdoptingSyncSetup = true
        let model = SyncSetupPairingModel(service: syncSetup)
        Task { @MainActor in
            await model.adopt(offer)
            isAutoAdoptingSyncSetup = false
        }
    }

    /// The user declined — don't re-prompt for this exact offer this session.
    public func declineSyncSetupOffer() {
        if let offer = cloudSyncUI.pendingSyncSetupOffer {
            dismissedSyncSetupOfferKeys.insert(Self.syncSetupOfferKey(offer))
        }
        cloudSyncUI.pendingSyncSetupOffer = nil
    }

    private static func syncSetupOfferKey(_ offer: SyncPairingRendezvous) -> String {
        offer.deviceID + ":" + offer.publicKeyData.base64EncodedString()
    }

    /// Poll for rendezvous offers every few seconds while the app is open, so the TV
    /// prompts within seconds of the phone opening its "set up from another device"
    /// screen — iCloud KVS delivery to a foreground-idle tvOS app is otherwise
    /// best-effort. Idempotent; guarded on the feature flag each tick.
    func startSyncSetupOfferPolling() {
        guard SyncSetupFeatureFlag().isEnabled, syncSetupOfferPollTask == nil else { return }
        syncSetupOfferPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                let keepGoing = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    if SyncSetupFeatureFlag().isEnabled { self.checkForSyncSetupOffer() }
                    return true
                }
                if !keepGoing { return }
            }
        }
    }

    /// Reset a corrupted/divergent sync state: wipe the iCloud zone and re-seed from
    /// THIS device. Other devices re-converge from the clean slate. Local config is
    /// untouched.
    public func resetCloudSync() {
        guard let cloudSync else { return }
        Task { await cloudSync.resetAndReseed() }
    }

    /// Repair a device stuck not-receiving (stale CKSyncEngine change token):
    /// re-download the whole zone fresh. Non-destructive to the shared cloud data.
    public func redownloadCloudSync() {
        guard let cloudSync else { return }
        Task { await cloudSync.redownloadFromCloud() }
    }

    // MARK: Publish side (V3 flat record capture)

    /// Capture the current canonical, NON-SECRET flat record map this device syncs:
    /// server descriptors, cosmetic profile DTOs, per-profile membership, and one
    /// record per per-profile setting key. Canonical (sorted-key) bytes so a
    /// re-capture after applying a remote change is byte-identical (the anti-clobber
    /// invariant). NEVER tokens; NOT the device-local active-profile selection.
    public func captureSyncRecords(fallback: [SyncRecordID: Data]) -> [SyncRecordID: Data] {
        var out: [SyncRecordID: Data] = [:]
        let localProfileIDs = Set(profilesModel.profiles.map(\.id))

        // Descriptors: this device's signed-in accounts PLUS the ones it has synced
        // but isn't signed into (pending). H2: keep the last-synced bytes when the
        // descriptor's meaningful fields are unchanged, so a per-device reachable-URL
        // difference doesn't churn/clobber the shared record.
        for d in Self.mergedAccountDescriptors(signedIn: accountsProviders.accounts) {
            let name = SyncRecordKey(kind: .descriptor, id: d.id).recordName
            if let bytes = Self.stableDescriptorBytes(d, fallback: fallback[name]) {
                out[name] = bytes
            }
        }
        // Profiles (default ALWAYS included ⇒ never sync-deleted), their membership,
        // and per-key settings.
        for p in profilesModel.profiles {
            if let data = CanonicalJSON.encode(ProfileSyncDTO(profile: p)) {
                out[SyncRecordKey(kind: .profile, id: p.id).recordName] = data
            }
            if let ids = profilesModel.storedActiveAccountIDs(for: p.id),
               let data = CanonicalJSON.encode(ids.sorted()) {
                out[SyncRecordKey(kind: .membership, id: p.id).recordName] = data
            }
            let ns = p.settingsNamespace(isDefault: profilesModel.isDefault(p))
            for (baseKey, blob) in ProfileSettingsTransfer.capture(namespace: ns) {
                out[SyncRecordKey(kind: .setting, id: p.id, subkey: baseKey).recordName] = blob
            }
        }
        // C5: back-fill setting/membership from last-synced bytes for not-yet-hydrated
        // profiles, without resurrecting a locally-deleted profile's children. Shared,
        // unit-tested logic in SyncCaptureFallback.
        return SyncCaptureFallback.merge(live: out, fallback: fallback, localProfileIDs: localProfileIDs)
    }

    /// H2 stability: if the last-synced descriptor bytes decode to a descriptor whose
    /// meaningful fields equal the freshly-derived one, reuse those bytes verbatim
    /// (preserving advisory `candidateBaseURLs`/`recordVersion`) so no spurious edit is
    /// published. Otherwise emit the new canonical bytes.
    static func stableDescriptorBytes(_ d: SyncedAccountDescriptor, fallback: Data?) -> Data? {
        if let fallback,
           let prev = CanonicalJSON.decode(SyncedAccountDescriptor.self, from: fallback) {
            // S7: never reuse RAW fallback bytes — a legacy record could carry a token
            // in candidateBaseURLs (which semantic equality ignores). Sanitize first,
            // so a tokenized fallback heals to a stripped upload instead of re-publishing
            // the credential.
            let cleanPrev = prev.sanitizingURLs()
            if cleanPrev.semanticallyEqualForSync(to: d) {
                return CanonicalJSON.encode(cleanPrev)
            }
        }
        return CanonicalJSON.encode(d)
    }

    /// Drop local state DERIVED from a previous iCloud account so it is never
    /// re-published into a newly-switched Apple ID (the pending "needs sign-in"
    /// servers came from the old account's sync). This device's OWN signed-in
    /// accounts and local profiles are untouched.
    public func clearRemoteDerivedSyncState() {
        var store = PendingSyncedServersStore()
        store.removeAll()
        refreshPendingSyncedServers()
    }

    /// The household's FULL server descriptor set: this device's signed-in accounts
    /// PLUS the descriptors it has synced but isn't signed into (pending). Including
    /// the pending ones is essential — otherwise a device would omit them from its
    /// snapshot and DELETE another device's servers for the whole household.
    static func mergedAccountDescriptors(signedIn accounts: [Account]) -> [SyncedAccountDescriptor] {
        var byID: [String: SyncedAccountDescriptor] = [:]
        for d in PendingSyncedServersStore().all { byID[d.id] = d.sanitizingURLs() }
        for a in accounts { byID[a.id] = SyncedAccountDescriptor(account: a) } // signed-in wins
        return byID.values.sorted { $0.id < $1.id }
    }

    // MARK: Apply side (V3 exact apply)

    /// Apply the EXACT local changes the ledger dictated (nil value = delete). CONFIG
    /// ONLY: roster + settings + membership + the pending-server list. Never signs a
    /// device in, never writes the Keychain. Applying exactly these keeps
    /// capture(apply) == record (no clobber).
    public func applySyncRecords(_ changes: SyncLocalChanges) {
        var profileUpserts: [String: ProfileSyncDTO] = [:]
        var profileDeletes: Set<String> = []
        var membershipSet: [String: [String]] = [:]
        var membershipClear: Set<String> = []
        var settingWrites: [(pid: String, key: String, blob: Data)] = []
        var settingRemoves: [(pid: String, key: String)] = []
        var descriptorsTouched = false
        var pendingStore = PendingSyncedServersStore()

        for (name, value) in changes {
            guard let key = SyncRecordKey.parse(name) else { continue }
            switch key.kind {
            case .profile:
                if let value, let dto = CanonicalJSON.decode(ProfileSyncDTO.self, from: value) {
                    profileUpserts[key.id] = dto
                } else if value == nil {
                    profileDeletes.insert(key.id)
                }
            case .membership:
                if let value, let ids = CanonicalJSON.decode([String].self, from: value) {
                    membershipSet[key.id] = ids
                } else if value == nil {
                    membershipClear.insert(key.id)
                }
            case .setting:
                if let value { settingWrites.append((key.id, key.subkey, value)) }
                else { settingRemoves.append((key.id, key.subkey)) }
            case .descriptor:
                descriptorsTouched = true
                if let value, let d = CanonicalJSON.decode(SyncedAccountDescriptor.self, from: value) {
                    pendingStore.upsertSynced(d.sanitizingURLs())
                } else if value == nil {
                    pendingStore.removeSynced(key.id)
                }
            }
        }

        // 1. Profiles: cosmetic upserts + deletions (default never deleted).
        if !profileUpserts.isEmpty || !profileDeletes.isEmpty {
            profilesModel.applySyncedProfileDTOs(profileUpserts, deletions: profileDeletes)
        }
        // 2. Settings: write/remove exactly the changed keys, under each profile's ns.
        for w in settingWrites {
            guard let ns = namespace(forProfileID: w.pid) else { continue }
            ProfileSettingsTransfer.applyOne(baseKey: w.key, blob: w.blob, namespace: ns)
        }
        for r in settingRemoves {
            guard let ns = namespace(forProfileID: r.pid) else { continue }
            ProfileSettingsTransfer.removeOne(baseKey: r.key, namespace: ns)
        }
        // 3. Membership: store the EXACT synced id set (no filter) so capture==apply;
        // consumers intersect with signed-in accounts at the point of USE. Apply even
        // for a not-yet-local profile (cross-batch ordering) — it's keyed by id and
        // re-read on capture once the profile lands (S5).
        if !membershipSet.isEmpty || !membershipClear.isEmpty {
            for (pid, ids) in membershipSet { profilesModel.setActiveAccountIDs(ids, for: pid) }
            for pid in membershipClear { profilesModel.clearActiveAccountIDs(for: pid) }
        }
        // 4. Descriptors → pending "needs sign-in" servers.
        if descriptorsTouched { refreshPendingSyncedServers() }

        rebuildSettingsModels()
        PlozzLog.sync.info("CloudSync: applied \(changes.count) exact change(s)")
    }

    /// The settings UserDefaults namespace for a profile id, or nil if unknown here.
    private func namespace(forProfileID pid: String) -> String?? {
        if let p = profilesModel.profiles.first(where: { $0.id == pid }) {
            return .some(p.settingsNamespace(isDefault: profilesModel.isDefault(p)))
        }
        // Profile not local yet (arrived in an earlier fetch batch than its own
        // record): apply the setting anyway under its derived namespace so it's present
        // when the profile lands — otherwise a later capture would omit it and delete
        // it for the household (S5). The default profile is always seeded locally, so an
        // absent profile is definitely non-default ⇒ namespace = its id.
        return .some(pid)
    }

    // MARK: Pending synced servers

    /// Recompute the pending (needs-sign-in) server list from the synced descriptor
    /// set this device has accumulated, and — on the Apple TV — queue a one-time
    /// prompt for any newly-detected server. Runs after applying config so
    /// `accountsProviders.accounts` reflects this device.
    public func refreshPendingSyncedServers() {
        var store = PendingSyncedServersStore()
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        let newly = store.newlyPending(excludingLocal: localIDs)
        cloudSyncUI.pendingSyncedServers = store.pending(excludingLocal: localIDs)
        if SyncSetupFeatureFlag().isEnabled, cloudSyncUI.pendingServerPrompt == nil,
           let first = newly.first {
            cloudSyncUI.pendingServerPrompt = first
            store.markPrompted(newly.map(\.id))
        }
    }

    /// The user chose to ignore a pending server — keep it listed (deletable) but
    /// stop surfacing it / prompting for it.
    public func ignorePendingSyncedServer(_ id: String) {
        var store = PendingSyncedServersStore()
        store.ignore(id)
        if cloudSyncUI.pendingServerPrompt?.id == id { cloudSyncUI.pendingServerPrompt = nil }
        cloudSyncUI.pendingSyncedServers = store.pending(excludingLocal: Set(accountsProviders.accounts.map(\.id)))
    }

    /// The user dismissed / handled the current prompt.
    public func clearPendingServerPrompt() { cloudSyncUI.pendingServerPrompt = nil }

    // MARK: Lifecycle + change observation

    /// Activate the engine (if enabled) and start observing local config changes.
    func startCloudSyncIfEnabled() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        guard let cloudSync else {
            PlozzLog.sync.error("CloudSync: no writable state dir — sync unavailable")
            return
        }
        Task { await cloudSync.activate() }
        armCloudConfigObservation()
        checkForSyncSetupOffer()
        startSyncSetupOfferPolling()
    }

    /// Re-arming Observation: fires whenever the roster or account set changes,
    /// then schedules a debounced publish and re-arms itself. Catches profile
    /// add/remove/rename/avatar and server add/remove; finer per-setting edits ride
    /// the next roster change or launch publish.
    func armCloudConfigObservation() {
        guard cloudSync != nil else { return }
        withObservationTracking {
            _ = profilesModel.profiles
            _ = accountsProviders.accounts.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleCloudPublish()
                self?.armCloudConfigObservation()
            }
        }
    }

    /// Coalesce a burst of edits into one publish shortly after they settle.
    func scheduleCloudPublish() {
        guard let cloudSync, SyncSetupFeatureFlag().isEnabled else { return }
        cloudPublishTask?.cancel()
        cloudPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            PlozzLog.sync.info("CloudSync: local config changed — publishing")
            await cloudSync.publishLocalChanges()
            _ = self
        }
    }

    /// Turn cross-device Sync & Setup on/off. Enabling activates CloudKit sync and
    /// starts observing; disabling stops publishing but NEVER deletes the shared
    /// cloud config (other devices keep syncing).
    public func setSyncSetupEnabled(_ on: Bool) {
        syncSetup.setEnabled(on)
        guard let cloudSync else { return }
        if on {
            Task { await cloudSync.activate() }
            armCloudConfigObservation()
            scheduleCloudPublish()
            startSyncSetupOfferPolling()
        } else {
            syncSetupOfferPollTask?.cancel()
            syncSetupOfferPollTask = nil
            cloudSyncUI.pendingSyncSetupOffer = nil
        }
    }
}
