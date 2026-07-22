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
            .appendingPathComponent("cloud-config.json")

        return CloudConfigSyncService(.init(
            containerIdentifier: cloudContainerIdentifier,
            stateFileURL: stateURL,
            isEnabled: { SyncSetupFeatureFlag().isEnabled },
            localSnapshot: { [weak appState] in
                guard let appState else { return SyncConfigSnapshot() }
                return await appState.currentSyncConfigSnapshot()
            },
            applyRemoteSnapshot: { [weak appState] snapshot in
                await appState?.applyRemoteConfigSnapshot(snapshot)
            },
            status: appState.cloudSyncStatus
        ))
    }

    /// Force an immediate two-way sync (manual "Sync Now").
    public func syncCloudNow() {
        guard let cloudSync else { return }
        Task { await cloudSync.syncNow() }
    }

    // MARK: Publish side

    /// The NON-SECRET snapshot this device publishes. Mirrors what the pairing
    /// `configProvider` builds (descriptors, profiles, per-profile settings +
    /// explicit membership) — no tokens, and NOT the device-local active-profile
    /// selection (that never syncs).
    public func currentSyncConfigSnapshot() -> SyncConfigSnapshot {
        let accounts = accountsProviders.accounts
        let profiles = profilesModel.profiles
        let settings = profiles.map { p in
            ProfileSettingsSnapshot(
                profileID: p.id,
                entries: ProfileSettingsTransfer.capture(
                    namespace: p.settingsNamespace(isDefault: profilesModel.isDefault(p))))
        }
        let memberships = Dictionary(uniqueKeysWithValues: profiles.compactMap { p in
            profilesModel.storedActiveAccountIDs(for: p.id).map { (p.id, $0) }
        })
        return SyncConfigSnapshot(
            accounts: accounts.map { SyncedAccountDescriptor(account: $0) },
            profiles: profiles.map { VersionedProfile(profile: $0) },
            profileSettings: settings,
            profileMemberships: memberships)
    }

    // MARK: Apply side

    /// Reconcile an incoming merged snapshot into the app's stores. CONFIG-ONLY:
    /// roster + settings + membership. Never signs a device in, never writes the
    /// Keychain. Safe to call for background CloudKit merges (unlike
    /// `applyReceivedSetup`, it does not mark first-run complete or enter the app).
    public func applyRemoteConfigSnapshot(_ snapshot: SyncConfigSnapshot) {
        // 1. Roster: update/add by id — INCLUDING the shared default profile — so an
        //    edit to the default's name/avatar converges (importProfiles' pairing
        //    guard would skip the default and strand its edits).
        let incomingProfiles = snapshot.profiles.map(\.profile)
        if !incomingProfiles.isEmpty { profilesModel.mergeSyncedProfiles(incomingProfiles) }

        // 2. Per-profile settings: reinstall under each matching profile's namespace.
        for snap in snapshot.profileSettings {
            guard let profile = profilesModel.profiles.first(where: { $0.id == snap.profileID }) else { continue }
            ProfileSettingsTransfer.apply(
                snap.entries,
                namespace: profile.settingsNamespace(isDefault: profilesModel.isDefault(profile)))
        }

        // 3. Per-profile server membership: apply for profiles present locally,
        //    scoped to accounts the synced household actually has.
        let syncedAccountIDs = Set(snapshot.accounts.map(\.id))
        for (pid, ids) in snapshot.profileMemberships {
            guard profilesModel.profiles.contains(where: { $0.id == pid }) else { continue }
            profilesModel.setActiveAccountIDs(ids.filter { syncedAccountIDs.contains($0) }, for: pid)
        }

        // NOTE: account *descriptors* travel in the mirror (non-secret server list)
        // but we do not auto-create pending accounts here — native sign-in on a new
        // device stays the pairing / add-server flow. Instead we record servers this
        // device isn't signed into as "pending", surfaced as Needs-sign-in entries.
        refreshPendingSyncedServers(from: snapshot)

        rebuildSettingsModels()
    }

    // MARK: Pending synced servers

    /// Recompute the pending (needs-sign-in) server list from a synced snapshot and,
    /// on the Apple TV, queue a one-time prompt for any newly-detected server. Runs
    /// after applying config so `accountsProviders.accounts` reflects this device.
    func refreshPendingSyncedServers(from snapshot: SyncConfigSnapshot) {
        var store = PendingSyncedServersStore()
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        let newlyPending = store.reconcile(
            syncedDescriptors: snapshot.accounts, localAccountIDs: localIDs)
        cloudSyncUI.pendingSyncedServers = store.pending
        // Offer to set up the first newly-detected server (one at a time), then mark
        // it prompted so it never nags again. Only when sync is enabled.
        if SyncSetupFeatureFlag().isEnabled, cloudSyncUI.pendingServerPrompt == nil,
           let first = newlyPending.first {
            cloudSyncUI.pendingServerPrompt = first
            store.markPrompted(newlyPending.map(\.id))
        }
    }

    /// The user chose to ignore a pending server — keep it listed (deletable) but
    /// stop surfacing it / prompting for it.
    public func ignorePendingSyncedServer(_ id: String) {
        var store = PendingSyncedServersStore()
        store.ignore(id)
        if cloudSyncUI.pendingServerPrompt?.id == id { cloudSyncUI.pendingServerPrompt = nil }
        cloudSyncUI.pendingSyncedServers = store.pending
    }

    /// The user dismissed / handled the current prompt.
    public func clearPendingServerPrompt() { cloudSyncUI.pendingServerPrompt = nil }

    /// Refresh the pending list from the current local snapshot (e.g. after a
    /// pairing/sign-in signs the device into one of them).
    public func refreshPendingSyncedServers() {
        refreshPendingSyncedServers(from: currentSyncConfigSnapshot())
    }

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
        }
    }
}
