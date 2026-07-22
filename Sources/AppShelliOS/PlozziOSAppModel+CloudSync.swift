#if os(iOS)
import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureSyncSetup
import FeatureSyncCloud

// MARK: - PlozziOSAppModel + CloudKit config auto-sync
//
// iOS counterpart of `AppState+CloudSync`. Same seams: publish the NON-SECRET
// household snapshot (descriptors, profiles, per-profile settings + membership) and
// reconcile an incoming merged snapshot CONFIG-ONLY (never signs in, never touches
// the Keychain). Gated on `SyncSetupFeatureFlag`; idempotent + loop-safe.
extension PlozziOSAppModel {

    private static let cloudContainerIdentifier = "iCloud.com.thatcube.Plozz"

    static func makeCloudSync(for model: PlozziOSAppModel) -> CloudConfigSyncService? {
        guard let baseDir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            ?? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let stateURL = baseDir
            .appendingPathComponent("PlozzSync", isDirectory: true)
            .appendingPathComponent("cloud-config-v3.json")

        return CloudConfigSyncService(.init(
            containerIdentifier: cloudContainerIdentifier,
            stateFileURL: stateURL,
            isEnabled: { SyncSetupFeatureFlag().isEnabled },
            captureRecords: { [weak model] fallback in
                guard let model else { return [:] }
                return await model.captureSyncRecords(fallback: fallback)
            },
            applyRecords: { [weak model] changes in
                await model?.applySyncRecords(changes)
            },
            onAccountSwitch: { [weak model] in
                await model?.clearRemoteDerivedSyncState()
            },
            status: model.cloudSyncStatus
        ))
    }

    /// Force an immediate two-way sync (manual "Sync Now").
    func syncCloudNow() {
        guard let cloudSync else { return }
        Task { await cloudSync.syncNow() }
    }

    // MARK: Publish side (V3 flat record capture)

    func captureSyncRecords(fallback: [SyncRecordID: Data]) -> [SyncRecordID: Data] {
        var out: [SyncRecordID: Data] = [:]
        let localProfileIDs = Set(profiles.profiles.map(\.id))
        for d in mergedAccountDescriptors() {
            let name = SyncRecordKey(kind: .descriptor, id: d.id).recordName
            if let bytes = Self.stableDescriptorBytes(d, fallback: fallback[name]) {
                out[name] = bytes
            }
        }
        for p in profiles.profiles {
            if let data = CanonicalJSON.encode(ProfileSyncDTO(profile: p)) {
                out[SyncRecordKey(kind: .profile, id: p.id).recordName] = data
            }
            if let ids = profiles.storedActiveAccountIDs(for: p.id),
               let data = CanonicalJSON.encode(ids.sorted()) {
                out[SyncRecordKey(kind: .membership, id: p.id).recordName] = data
            }
            let ns = p.settingsNamespace(isDefault: profiles.isDefault(p))
            for (baseKey, blob) in ProfileSettingsTransfer.capture(namespace: ns) {
                out[SyncRecordKey(kind: .setting, id: p.id, subkey: baseKey).recordName] = blob
            }
        }
        // C5: shared back-fill logic (out-of-order safe, no deleted-profile orphans).
        return SyncCaptureFallback.merge(live: out, fallback: fallback, localProfileIDs: localProfileIDs)
    }

    /// H2 stability: reuse the last-synced descriptor bytes when the meaningful fields
    /// are unchanged (preserving per-device advisory URLs), else emit fresh bytes.
    static func stableDescriptorBytes(_ d: SyncedAccountDescriptor, fallback: Data?) -> Data? {
        if let fallback,
           let prev = CanonicalJSON.decode(SyncedAccountDescriptor.self, from: fallback) {
            // S7: sanitize the fallback before reuse so a legacy tokenized
            // candidateBaseURLs heals instead of being re-published.
            let cleanPrev = prev.sanitizingURLs()
            if cleanPrev.semanticallyEqualForSync(to: d) {
                return CanonicalJSON.encode(cleanPrev)
            }
        }
        return CanonicalJSON.encode(d)
    }

    /// Drop state derived from a previous iCloud account on an account switch, so it's
    /// never re-published into the new Apple ID.
    func clearRemoteDerivedSyncState() {
        var store = PendingSyncedServersStore()
        store.removeAll()
    }

    /// This device's signed-in accounts PLUS descriptors synced-but-not-signed-into,
    /// so a device never deletes another's servers by omitting them.
    private func mergedAccountDescriptors() -> [SyncedAccountDescriptor] {
        var byID: [String: SyncedAccountDescriptor] = [:]
        for d in PendingSyncedServersStore().all { byID[d.id] = d.sanitizingURLs() }
        for a in accountsProviders.accounts { byID[a.id] = SyncedAccountDescriptor(account: a) }
        return byID.values.sorted { $0.id < $1.id }
    }

    // MARK: Apply side (V3 exact apply)

    func applySyncRecords(_ changes: SyncLocalChanges) {
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
                if let value, let dto = CanonicalJSON.decode(ProfileSyncDTO.self, from: value) { profileUpserts[key.id] = dto }
                else if value == nil { profileDeletes.insert(key.id) }
            case .membership:
                if let value, let ids = CanonicalJSON.decode([String].self, from: value) { membershipSet[key.id] = ids }
                else if value == nil { membershipClear.insert(key.id) }
            case .setting:
                if let value { settingWrites.append((key.id, key.subkey, value)) }
                else { settingRemoves.append((key.id, key.subkey)) }
            case .descriptor:
                descriptorsTouched = true
                if let value, let d = CanonicalJSON.decode(SyncedAccountDescriptor.self, from: value) { pendingStore.upsertSynced(d.sanitizingURLs()) }
                else if value == nil { pendingStore.removeSynced(key.id) }
            }
        }

        if !profileUpserts.isEmpty || !profileDeletes.isEmpty {
            profiles.applySyncedProfileDTOs(profileUpserts, deletions: profileDeletes)
        }
        for w in settingWrites {
            guard let ns = namespace(forProfileID: w.pid) else { continue }
            ProfileSettingsTransfer.applyOne(baseKey: w.key, blob: w.blob, namespace: ns)
        }
        for r in settingRemoves {
            guard let ns = namespace(forProfileID: r.pid) else { continue }
            ProfileSettingsTransfer.removeOne(baseKey: r.key, namespace: ns)
        }
        // Membership: store the EXACT synced id set (no filter) so capture==apply;
        // consumers intersect with signed-in accounts at the point of use.
        if !membershipSet.isEmpty || !membershipClear.isEmpty {
            for (pid, ids) in membershipSet { profiles.setActiveAccountIDs(ids, for: pid) }
            for pid in membershipClear { profiles.clearActiveAccountIDs(for: pid) }
        }
        if descriptorsTouched { _ = pendingStore }  // descriptors persisted; iOS has no pending-server UI

        // Rebuild the active profile's settings model so applied preferences take
        // effect immediately.
        selectProfile(profiles.activeProfileID)
    }

    private func namespace(forProfileID pid: String) -> String?? {
        if let p = profiles.profiles.first(where: { $0.id == pid }) {
            return .some(p.settingsNamespace(isDefault: profiles.isDefault(p)))
        }
        // Apply even for a not-yet-local profile (cross-batch ordering, S5); the default
        // profile is always seeded locally, so an absent profile is non-default.
        return .some(pid)
    }

    // MARK: Lifecycle + change observation

    func startCloudSyncIfEnabled() {
        guard SyncSetupFeatureFlag().isEnabled, let cloudSync else { return }
        Task { await cloudSync.activate() }
        armCloudConfigObservation()
    }

    func armCloudConfigObservation() {
        guard cloudSync != nil else { return }
        withObservationTracking {
            _ = profiles.profiles
            _ = accountsProviders.accounts.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleCloudPublish()
                self?.armCloudConfigObservation()
            }
        }
    }

    func scheduleCloudPublish() {
        guard let cloudSync, SyncSetupFeatureFlag().isEnabled else { return }
        cloudPublishTask?.cancel()
        cloudPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await cloudSync.publishLocalChanges()
            _ = self
        }
    }

    /// Turn cross-device Sync & Setup on/off. Enabling activates CloudKit sync;
    /// disabling stops publishing but never deletes the shared cloud config.
    func setSyncSetupEnabled(_ on: Bool) {
        syncSetup.setEnabled(on)
        guard let cloudSync else { return }
        if on {
            Task { await cloudSync.activate() }
            armCloudConfigObservation()
            scheduleCloudPublish()
        }
    }

    /// Lightweight foreground pull (iOS). Same effect as tapping Sync Now's fetch.
    func syncCloudOnForeground() {
        guard let cloudSync, SyncSetupFeatureFlag().isEnabled else { return }
        Task { await cloudSync.fetchNow() }
    }

    /// Reset a corrupted/divergent sync: wipe the iCloud zone and re-seed from this
    /// device. Local config is untouched.
    func resetCloudSync() {
        guard let cloudSync else { return }
        Task { await cloudSync.resetAndReseed() }
    }

    /// Repair a device stuck not-receiving (stale change token): re-download the
    /// whole zone fresh. Non-destructive to the shared cloud data.
    func redownloadCloudSync() {
        guard let cloudSync else { return }
        Task { await cloudSync.redownloadFromCloud() }
    }
}
#endif
