#if os(iOS)
import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureSyncSetup
import FeatureSyncCloud
import UIKit

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
        // Household-removed (tombstoned) accounts are excluded from descriptors and get
        // a `.removal` record instead, so peers sign them out and stop re-publishing.
        let removedStore = RemovedAccountsStore()
        let removedIDs = removedStore.removedIDs
        for d in mergedAccountDescriptors() where !removedIDs.contains(d.id) {
            let name = SyncRecordKey(kind: .descriptor, id: d.id).recordName
            if let bytes = Self.stableDescriptorBytes(d, fallback: fallback[name]) {
                out[name] = bytes
            }
        }
        for (id, epoch) in removedStore.all {
            if let data = CanonicalJSON.encode(AccountRemovalDTO(accountID: id, removedAtEpoch: epoch)) {
                out[SyncRecordKey(kind: .removal, id: id).recordName] = data
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
                // Preserve the original publisher's origin, but back-fill it once if the
                // stored record predates origin stamping and this device knows it.
                var merged = cleanPrev
                if merged.originDeviceName == nil, d.originDeviceName != nil {
                    merged.originDeviceName = d.originDeviceName
                    merged.originDeviceKind = d.originDeviceKind
                }
                return CanonicalJSON.encode(merged)
            }
            // Meaningful fields changed (e.g. a rename) → publish the new descriptor,
            // but keep the ORIGINAL publisher's origin rather than the editing device.
            var out = d
            if cleanPrev.originDeviceName != nil {
                out.originDeviceName = cleanPrev.originDeviceName
                out.originDeviceKind = cleanPrev.originDeviceKind
            }
            return CanonicalJSON.encode(out)
        }
        return CanonicalJSON.encode(d)
    }

    /// Drop state derived from a previous iCloud account on an account switch, so it's
    /// never re-published into the new Apple ID.
    func clearRemoteDerivedSyncState() {
        var store = PendingSyncedServersStore()
        store.removeAll()
        var removed = RemovedAccountsStore()
        removed.removeAll()
    }

    /// This device's signed-in accounts PLUS descriptors synced-but-not-signed-into,
    /// so a device never deletes another's servers by omitting them. Local signed-in
    /// accounts are stamped with THIS device as the origin (preserved across re-publish
    /// via `semanticallyEqualForSync`, which ignores origin) so peers can show
    /// "Set up with <this device>".
    private func mergedAccountDescriptors() -> [SyncedAccountDescriptor] {
        var byID: [String: SyncedAccountDescriptor] = [:]
        for d in PendingSyncedServersStore().all { byID[d.id] = d.sanitizingURLs() }
        let originName = DeviceDisplayName.current(fallback: UIDevice.current.name)
        let originKind = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        for a in accountsProviders.accounts {
            byID[a.id] = SyncedAccountDescriptor(account: a).stampingOrigin(name: originName, kind: originKind)
        }
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
        var removalUpserts: [String: Int] = [:]
        var removalClears: Set<String> = []

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
            case .removal:
                if let value, let dto = CanonicalJSON.decode(AccountRemovalDTO.self, from: value) { removalUpserts[key.id] = dto.removedAtEpoch }
                else if value == nil { removalClears.insert(key.id) }
            }
        }

        // Household removals: record the tombstone, sign the account out here if this
        // device holds it, and drop it from the pending list. A cleared removal (the
        // server was re-added on a peer) lets its descriptor flow again.
        if !removalUpserts.isEmpty || !removalClears.isEmpty {
            descriptorsTouched = true   // re-add clears must refresh pending/auto-connect too
            var removed = RemovedAccountsStore()
            for (id, epoch) in removalUpserts {
                removed.markRemoved(id, at: epoch)
                pendingStore.removeSynced(id)
                // A queued setup prompt for a now-removed server must not linger.
                if pendingSyncedServerPrompt?.id == id { pendingSyncedServerPrompt = nil }
                if accountsProviders.accounts.contains(where: { $0.id == id }) {
                    removeAccount(id: id)
                }
            }
            for id in removalClears { removed.clear(id) }
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
        if descriptorsTouched {
            // Sign in first from any synced iCloud-Keychain credential, THEN recompute
            // the pending list — so a just-synced server the user already signed into
            // elsewhere connects silently instead of prompting for a manual sign-in.
            autoConnectFromSyncedCredentials()
            refreshPendingSyncedServers()
        }

        // Rebuild the active profile's settings model so applied preferences take
        // effect immediately.
        selectProfile(profiles.activeProfileID)
    }

    /// Recompute the "servers from your other devices" list (synced descriptors this
    /// device isn't signed into and hasn't ignored), for display on iOS — and queue a
    /// one-time "set it up here?" prompt for any newly-detected media server. Mirrors
    /// tvOS `AppState.refreshPendingSyncedServers()`.
    func refreshPendingSyncedServers() {
        var store = PendingSyncedServersStore()
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        // Household-removed (tombstoned) servers are hidden and never prompted here.
        let removedIDs = RemovedAccountsStore().removedIDs
        // If the queued prompt's server has since been signed in here (e.g. a synced
        // credential arrived and auto-connected) or was removed, drop the prompt.
        if let prompt = pendingSyncedServerPrompt,
           removedIDs.contains(prompt.id) || localIDs.contains(prompt.id) {
            pendingSyncedServerPrompt = nil
        }
        pendingSyncedServers = store.pending(excludingLocal: localIDs).filter { !removedIDs.contains($0.id) }
        guard SyncSetupFeatureFlag().isEnabled, pendingSyncedServerPrompt == nil else { return }
        let newly = store.newlyPending(excludingLocal: localIDs).filter { !removedIDs.contains($0.id) }
        // Only nudge for media servers we can sign into here (Jellyfin/Emby/Plex), AND
        // only when there's no synced login already waiting — if this device already has
        // the iCloud-Keychain credential (e.g. published by the user's iPhone),
        // `autoConnectFromSyncedCredentials()` signs in silently, so a manual "add this
        // server?" prompt would be redundant. Media shares are set up differently.
        if let first = newly.first(where: { $0.provider != .mediaShare && !hasPortableCredential($0.id) }) {
            pendingSyncedServerPrompt = first
        }
        // Mark every newly-pending id prompted (including skipped media shares and
        // auto-connectable ones) so the one-time nudge never re-fires for them.
        if !newly.isEmpty {
            store.markPrompted(newly.map(\.id))
        }
    }

    /// Stop surfacing a synced server the user doesn't want here.
    func ignorePendingSyncedServer(_ id: String) {
        var store = PendingSyncedServersStore()
        store.ignore(id)
        if pendingSyncedServerPrompt?.id == id { pendingSyncedServerPrompt = nil }
        refreshPendingSyncedServers()
    }

    /// The user dismissed / handled the current one-time server prompt.
    func clearPendingSyncedServerPrompt() { pendingSyncedServerPrompt = nil }

    /// Whether the delete UI should offer the "Everywhere" vs "This device" choice.
    /// Simply whether cross-device sync is on: enabling sync is the multi-device
    /// intent, and the destructive "Everywhere" action has its own second confirm — so
    /// we don't gate on live device detection (which lags iCloud propagation).
    var offersRemoveEverywhere: Bool { SyncSetupFeatureFlag().isEnabled }

    /// Whether the user has other devices on this iCloud account (a recently-seen
    /// device other than this one in the presence registry).
    var hasOtherHouseholdDevices: Bool {
        !HouseholdDevicesStore().otherDevices(excluding: deviceID).isEmpty
    }

    /// Servers detected from another device that genuinely need the user to act to
    /// bring them here — the trigger for the full-page "we found your setup" screen.
    ///
    /// PARAMOUNT: this must never include something the user already has, or the app
    /// would falsely announce "we found X" for a server that's already present. So it
    /// starts from `pendingSyncedServers` (already excludes the local roster and
    /// removed tombstones) and additionally drops anything that will silently
    /// auto-connect from an iCloud-Keychain credential (`hasPortableCredential` — the
    /// iOS→iOS case, which needs no screen at all). What remains is servers whose only
    /// login lives on a device that can't hand it over automatically — in practice the
    /// Apple TV. Media shares (NFS/SMB/WebDAV/…) are INCLUDED: they're never published
    /// to the synced credential store (so never auto-connect) but the pairing transfer
    /// this page runs DOES bring them over, so listing them keeps the "we found" summary
    /// honest — otherwise a share would appear only after setup, which is confusing.
    var pendingServersNeedingSetup: [SyncedAccountDescriptor] {
        pendingSyncedServers.filter { !hasPortableCredential($0.id) }
    }

    /// The friendly origin device name shared by the detected servers ("Brando TV"),
    /// when the publisher stamped one — for the "Set Up from …" copy.
    var pendingSetupOriginName: String? {
        for d in pendingServersNeedingSetup {
            let n = d.originDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n, !n.isEmpty { return n }
        }
        return nil
    }

    /// The origin device kind ("tv"/"pad"/"phone"/"mac") shared by the detected
    /// servers, for the inline device icon.
    var pendingSetupOriginKind: String? {
        for d in pendingServersNeedingSetup where d.originDeviceKind != nil {
            return d.originDeviceKind
        }
        return nil
    }

    /// Record this device in the household presence registry (so peers know it exists).
    func heartbeatHouseholdPresence() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        HouseholdDevicesStore().heartbeat(
            deviceID: deviceID,
            deviceName: DeviceDisplayName.current(fallback: UIDevice.current.name))
    }

    /// Remove a server from EVERY device on this iCloud account: publish a removal
    /// tombstone so peers sign it out and stop re-publishing it, remove it here, and
    /// push now. Reversible by re-adding the server anywhere.
    func removeAccountEverywhere(id: String) {
        var removed = RemovedAccountsStore()
        removed.markRemoved(id, at: Int(Date().timeIntervalSince1970))
        var pending = PendingSyncedServersStore()
        pending.removeSynced(id)
        removeAccount(id: id)   // local removal (also drops the portable credential)
        refreshPendingSyncedServers()
        scheduleCloudPublish()  // propagate the tombstone + delete the descriptor
    }

    /// Clear any household-removal tombstone for an account the user just (re)added.
    func clearRemovalTombstone(for id: String) {
        var removed = RemovedAccountsStore()
        guard removed.isRemoved(id) else { return }
        removed.clear(id)
        scheduleCloudPublish()
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
        heartbeatHouseholdPresence()          // register this device in the household
        publishPortableCredentials()          // share this device's logins via iCloud Keychain
        autoConnectFromSyncedCredentials()    // pick up other devices' logins automatically
        refreshPendingSyncedServers()         // after auto-connect, so signed-in servers don't prompt
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
            // A local sign-in/out changed the account set → refresh the credentials
            // shared via iCloud Keychain so the user's other devices track it.
            await MainActor.run { self?.publishPortableCredentials() }
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
            heartbeatHouseholdPresence()
            publishPortableCredentials()
            autoConnectFromSyncedCredentials()
        } else {
            HouseholdDevicesStore().remove(deviceID: deviceID)
        }
    }

    /// Lightweight foreground pull (iOS). Same effect as tapping Sync Now's fetch.
    func syncCloudOnForeground() {
        guard let cloudSync, SyncSetupFeatureFlag().isEnabled else { return }
        Task { await cloudSync.fetchNow() }
        heartbeatHouseholdPresence()
        checkForSyncSetupOffer()
        publishPortableCredentials()
        autoConnectFromSyncedCredentials()    // sign in from synced logins first…
        refreshPendingSyncedServers()         // …so already-synced servers don't prompt
    }

    /// Same-Apple-ID credential auto-skip (SOURCE side). If another of the user's
    /// devices is asking to be set up (it published a rendezvous to iCloud, e.g. an
    /// Apple TV the user just tapped "add my servers" on), SURFACE a one-tap confirm —
    /// we never push credentials silently. The single tap is neither typing a code nor
    /// re-signing in, so it stays zero-friction, but it keeps a human in the loop so a
    /// shared/stale Apple ID can't silently harvest tokens (matches Apple's "set up new
    /// device" pattern, which also confirms on the source).
    func checkForSyncSetupOffer() {
        guard SyncSetupFeatureFlag().isEnabled, !isAutoAdoptingSyncSetup, pendingSyncSetupOffer == nil else { return }
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        guard !localIDs.isEmpty else { return }         // nothing to give
        // Surface the freshest offer the user hasn't already declined — so declining
        // one device still lets another simultaneously-advertising device prompt. A
        // per-server request is only fulfillable if THIS device holds that account.
        guard let offer = syncSetup.discoverRendezvousTargets().first(where: { offer in
            guard !dismissedSyncSetupOfferKeys.contains(Self.offerKey(offer)) else { return false }
            if let requested = offer.requestedAccountID { return localIDs.contains(requested) }
            return true
        }) else { return }
        pendingSyncSetupOffer = offer
    }

    /// The user confirmed — push config + credentials to the offered device (pinned
    /// key ⇒ no SAS, no typing).
    func confirmSyncSetupOffer() {
        guard let offer = pendingSyncSetupOffer else { return }
        pendingSyncSetupOffer = nil
        isAutoAdoptingSyncSetup = true
        let model = SyncSetupPairingModel(service: syncSetup)
        Task { @MainActor in
            await model.adopt(offer)
            isAutoAdoptingSyncSetup = false
        }
    }

    /// The user declined — don't re-prompt for this exact offer.
    func declineSyncSetupOffer() {
        if let offer = pendingSyncSetupOffer {
            dismissedSyncSetupOfferKeys.insert(Self.offerKey(offer))
        }
        pendingSyncSetupOffer = nil
    }

    private static func offerKey(_ offer: SyncPairingRendezvous) -> String {
        offer.deviceID + ":" + offer.publicKeyData.base64EncodedString()
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

    /// DEBUG: nuke the ENTIRE household from iCloud so you can test a true cold start
    /// (e.g. "set up only on the Apple TV, then fresh-install the iPad"). Unlike
    /// `resetCloudSync` (which deletes then immediately RE-uploads from this device),
    /// this deletes and does NOT republish, then takes this device out of sync so it
    /// can't refill iCloud. It:
    ///   1. deletes every CloudKit config + removal-tombstone record (flushed to peers
    ///      as normal deletions, so their synced view empties too);
    ///   2. removes every synchronizable iCloud-Keychain login (propagates the deletion
    ///      through iCloud Keychain so no device silently auto-reconnects);
    ///   3. wipes this device's local roster/profiles/sync bookkeeping (first-run);
    ///   4. turns iCloud Sync OFF here so this device stays out of the household until
    ///      you re-enable it — leaving iCloud genuinely empty for the next publisher.
    func eraseEverythingFromICloudForDebugging() {
        let cloud = cloudSync
        Task { @MainActor in
            await cloud?.deleteAllServerData()   // step 1 (flushes deletes to peers)
            removeAllPortableCredentials()        // step 2
            resetToFirstRunForDebugging()         // step 3
            setSyncSetupEnabled(false)            // step 4
        }
    }
}
#endif
