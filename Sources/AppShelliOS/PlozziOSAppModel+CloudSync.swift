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
            captureRecords: { [weak model] in
                guard let model else { return [:] }
                return await model.captureSyncRecords()
            },
            applyRecords: { [weak model] changes in
                await model?.applySyncRecords(changes)
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

    func captureSyncRecords() -> [SyncRecordID: Data] {
        var out: [SyncRecordID: Data] = [:]
        for d in mergedAccountDescriptors() {
            if let data = CanonicalJSON.encode(d) {
                out[SyncRecordKey(kind: .descriptor, id: d.id).recordName] = data
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
        return out
    }

    /// This device's signed-in accounts PLUS descriptors synced-but-not-signed-into,
    /// so a device never deletes another's servers by omitting them.
    private func mergedAccountDescriptors() -> [SyncedAccountDescriptor] {
        var byID: [String: SyncedAccountDescriptor] = [:]
        for d in PendingSyncedServersStore().all { byID[d.id] = d }
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
                if let value, let d = CanonicalJSON.decode(SyncedAccountDescriptor.self, from: value) { pendingStore.upsertSynced(d) }
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
        if !membershipSet.isEmpty || !membershipClear.isEmpty {
            let syncedIDs = Set(mergedAccountDescriptors().map(\.id))
            for (pid, ids) in membershipSet where profiles.profiles.contains(where: { $0.id == pid }) {
                profiles.setActiveAccountIDs(ids.filter { syncedIDs.contains($0) }, for: pid)
            }
            for pid in membershipClear { profiles.clearActiveAccountIDs(for: pid) }
        }
        if descriptorsTouched { _ = pendingStore }  // descriptors persisted; iOS has no pending-server UI

        // Rebuild the active profile's settings model so applied preferences take
        // effect immediately.
        selectProfile(profiles.activeProfileID)
    }

    private func namespace(forProfileID pid: String) -> String?? {
        guard let p = profiles.profiles.first(where: { $0.id == pid }) else { return nil }
        return .some(p.settingsNamespace(isDefault: profiles.isDefault(p)))
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
