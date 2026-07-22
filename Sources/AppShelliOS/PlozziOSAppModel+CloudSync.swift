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
            .appendingPathComponent("cloud-config.json")

        return CloudConfigSyncService(.init(
            containerIdentifier: cloudContainerIdentifier,
            stateFileURL: stateURL,
            isEnabled: { SyncSetupFeatureFlag().isEnabled },
            localSnapshot: { [weak model] in
                guard let model else { return SyncConfigSnapshot() }
                return await model.currentSyncConfigSnapshot()
            },
            applyRemoteSnapshot: { [weak model] snapshot in
                await model?.applyRemoteConfigSnapshot(snapshot)
            },
            status: model.cloudSyncStatus
        ))
    }

    /// Force an immediate two-way sync (manual "Sync Now").
    func syncCloudNow() {
        guard let cloudSync else { return }
        Task { await cloudSync.syncNow() }
    }

    // MARK: Publish side

    func currentSyncConfigSnapshot() -> SyncConfigSnapshot {
        let accounts = accountsProviders.accounts
        let profileList = profiles.profiles
        let settings = profileList.map { p in
            ProfileSettingsSnapshot(
                profileID: p.id,
                entries: ProfileSettingsTransfer.capture(
                    namespace: p.settingsNamespace(isDefault: profiles.isDefault(p))))
        }
        let memberships = Dictionary(uniqueKeysWithValues: profileList.compactMap { p in
            profiles.storedActiveAccountIDs(for: p.id).map { (p.id, $0) }
        })
        return SyncConfigSnapshot(
            accounts: accounts.map { SyncedAccountDescriptor(account: $0) },
            profiles: profileList.map { VersionedProfile(profile: $0) },
            profileSettings: settings,
            profileMemberships: memberships)
    }

    // MARK: Apply side

    func applyRemoteConfigSnapshot(_ snapshot: SyncConfigSnapshot) {
        let incomingProfiles = snapshot.profiles.map(\.profile)
        if !incomingProfiles.isEmpty { profiles.mergeSyncedProfiles(incomingProfiles) }

        for snap in snapshot.profileSettings {
            guard let profile = profiles.profiles.first(where: { $0.id == snap.profileID }) else { continue }
            ProfileSettingsTransfer.apply(
                snap.entries,
                namespace: profile.settingsNamespace(isDefault: profiles.isDefault(profile)))
        }

        let syncedAccountIDs = Set(snapshot.accounts.map(\.id))
        for (pid, ids) in snapshot.profileMemberships {
            guard profiles.profiles.contains(where: { $0.id == pid }) else { continue }
            profiles.setActiveAccountIDs(ids.filter { syncedAccountIDs.contains($0) }, for: pid)
        }

        // Rebuild the active profile's settings model so applied preferences take
        // effect immediately (mirrors applyReceivedSetup's refresh).
        selectProfile(profiles.activeProfileID)
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
}
#endif
