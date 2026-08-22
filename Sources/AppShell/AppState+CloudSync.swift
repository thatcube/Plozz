import Foundation
import Observation
import AppRuntime
import CoreModels
import CoreSecureStore
import CoreNetworking
import FeatureSyncSetup
import FeatureSyncCloud
import FeatureWatchlistCore

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

    static func mediaAliasStorageDirectory() -> URL? {
        writableStateDirectory()?
            .appendingPathComponent("PlozzMediaState", isDirectory: true)
            .appendingPathComponent("AliasLedger", isDirectory: true)
    }

    /// Build the ONE multiplexed service, capturing `self` weakly for the primary
    /// (Config V3) and media-state (`PlozzMediaStateV1`) channels' closures. Apple
    /// permits exactly one active `CKSyncEngine` per private database, so both
    /// channels are configured on this SINGLE `CloudConfigSyncService` instead of
    /// two separate services (see `CloudConfigSyncService`'s multiplexing doc
    /// comment). The enabled-check reads the device-wide flag straight from
    /// `UserDefaults` (thread-safe) so it needs no main-actor hop. Returns `nil`
    /// only if no writable state location exists.
    static func makeCloudSync(for appState: AppState) -> CloudConfigSyncService? {
        // tvOS restricts persistent storage — .applicationSupportDirectory often
        // can't be created — so fall back to Caches (CKSyncEngine can rebuild its
        // state if it's ever purged). Per-Apple-TV-user (both dirs are partitioned
        // by the runs-as-current-user entitlement), so each system user's engine
        // state stays separate.
        guard let baseDir = Self.writableStateDirectory() else { return nil }
        let syncDir = baseDir.appendingPathComponent("PlozzSync", isDirectory: true)
        let configStateURL = syncDir.appendingPathComponent("cloud-config-v3.json")
        let mediaStateURL = syncDir.appendingPathComponent("cloud-media-state-v1.json")

        let mediaChannel = CloudConfigSyncService.ChannelConfiguration(
            schema: .mediaStateV1,
            stateFileURL: mediaStateURL,
            captureRecords: { [weak appState] fallback in
                guard let appState else { return fallback }
                return await appState.captureMediaStateSyncRecords(fallback: fallback)
            },
            applyRecords: { [weak appState] changes in
                await appState?.applyMediaStateSyncRecords(changes)
            }
        )

        // Tracker sign-ins. Same shared bridge on both shells; the payload is
        // encrypted end-to-end, and the Keychain stays the local store of record.
        let trackerTokenChannel = CloudConfigSyncService.ChannelConfiguration(
            schema: .trackerTokensV1,
            stateFileURL: syncDir.appendingPathComponent(
                "cloud-tracker-tokens-v1.json"
            ),
            captureRecords: { fallback in
                TrackerTokenSyncBridge.capture(fallback: fallback)
            },
            applyRecords: { changes in
                TrackerTokenSyncBridge.apply(changes)
            }
        )

        // A sign-in that arrived from another device is just bytes in the
        // Keychain until the services re-read it, so re-run their status checks.
        NotificationCenter.default.addObserver(
            forName: .plozzTrackerTokensDidChangeRemotely,
            object: nil,
            queue: nil
        ) { [weak appState] _ in
            Task { @MainActor in
                guard let appState else { return }
                await appState.traktService.refreshStatus()
                await appState.simklService.refreshStatus()
                await appState.anilistService.refreshStatus()
                await appState.malService.refreshStatus()
            }
        }

        // A local sign-in has nothing to observe it, so the store raises this and
        // the engine publishes it rather than waiting for the next sweep.
        SyncedTokenRegistry.shared.setChangeHandler { [weak appState] in
            Task { await appState?.cloudSync?.publishLocalChanges() }
        }

        return CloudConfigSyncService(.init(
            containerIdentifier: cloudContainerIdentifier,
            stateFileURL: configStateURL,
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
        ), channels: [mediaChannel, trackerTokenChannel])
    }

    /// Force an immediate two-way sync (manual "Sync Now").
    public func syncCloudNow() {
        let config = cloudSync
        guard let config else { return }
        Task {
            await config.syncNow()
        }
    }

    /// Lightweight pull when the app comes to the foreground, so config changed on
    /// another device appears promptly (tvOS push is unreliable).
    public func syncCloudOnForeground() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        let config = cloudSync
        Task {
            await config?.fetchNow()
        }
        heartbeatHouseholdPresence()
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
        // Pairing hands another device this household's servers, profiles and
        // credentials, and the receiver opens in a grown-up profile. That is a
        // grown-up decision, so it isn't offered from inside an enforced Kids
        // Profile.
        guard !profileFlow.managementRequiresParentalPIN else { return }
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
        guard !profileFlow.managementRequiresParentalPIN else { return }
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
    /// best-effort. Also pulls config changes roughly every 30s so household edits
    /// made elsewhere (e.g. a "Remove Everywhere") converge on an idle, already-open
    /// Apple TV without the user backgrounding the app (tvOS push is unreliable).
    /// Idempotent; guarded on the feature flag each tick.
    func startSyncSetupOfferPolling() {
        guard SyncSetupFeatureFlag().isEnabled, syncSetupOfferPollTask == nil else { return }
        syncSetupOfferPollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                tick += 1
                let fetchConfig = tick % 4 == 0   // ~every 32s
                let keepGoing = await MainActor.run { () -> Bool in
                    guard let self, SyncSetupFeatureFlag().isEnabled else { return self != nil }
                    self.checkForSyncSetupOffer()
                    if fetchConfig {
                        let config = self.cloudSync
                        Task {
                            await config?.fetchNow()
                        }
                    }
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
        let config = cloudSync
        Task {
            await config?.resetAndReseed()
        }
    }

    /// Repair a device stuck not-receiving (stale CKSyncEngine change token):
    /// re-download the whole zone fresh. Non-destructive to the shared cloud data.
    public func redownloadCloudSync() {
        let config = cloudSync
        Task {
            await config?.redownloadFromCloud()
        }
    }

    /// DEBUG: nuke the ENTIRE household from iCloud so you can test a true cold start
    /// (e.g. "set up only on this Apple TV, then fresh-install another device"). Unlike
    /// `resetCloudSync` (which deletes then immediately RE-uploads from this device),
    /// this deletes and does NOT republish, then takes this device out of sync so it
    /// can't refill iCloud. It:
    ///   1. deletes every CloudKit config + removal-tombstone record (flushed to peers
    ///      as normal deletions, so their synced view empties too);
    ///   2. wipes this device's local roster/profiles/sync bookkeeping (first-run);
    ///   3. turns iCloud Sync OFF here so this device stays out of the household until
    ///      you re-enable it — leaving iCloud genuinely empty for the next publisher.
    /// tvOS holds no synchronizable iCloud-Keychain logins (that channel is iOS-only),
    /// so there are none to purge here.
    public func eraseEverythingFromICloudForDebugging() {
        let config = cloudSync
        Task { @MainActor in
            await config?.deleteAllServerData()
            for profileID in profilesModel.profiles.map(\.id) {
                do {
                    try await mediaAliasLedger.removeProfile(profileID)
                    try universalWatchlist.removeProfile(profileID)
                } catch {
                    PlozzLog.sync.error(
                        "Media aliases: debug reset failed for one profile: \(error.localizedDescription)"
                    )
                }
            }
            resetToFirstRunForDebugging()         // step 2
            setSyncSetupEnabled(false)            // step 3
        }
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
        // difference doesn't churn/clobber the shared record. Household-removed
        // (tombstoned) accounts are excluded so their descriptor is deleted from the
        // zone; a `.removal` record is published for each instead.
        let removedStore = RemovedAccountsStore()
        let removedIDs = removedStore.removedIDs
        for d in Self.mergedAccountDescriptors(signedIn: accountsProviders.accounts)
        where !removedIDs.contains(d.id) {
            let name = SyncRecordKey(kind: .descriptor, id: d.id).recordName
            if let bytes = Self.stableDescriptorBytes(d, fallback: fallback[name]) {
                out[name] = bytes
            }
        }
        // Removal tombstones: one per household-removed account, so every device signs
        // it out and stops re-publishing it.
        for (id, epoch) in removedStore.all {
            if let data = CanonicalJSON.encode(AccountRemovalDTO(accountID: id, removedAtEpoch: epoch)) {
                out[SyncRecordKey(kind: .removal, id: id).recordName] = data
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
            let cleanPrev = prev.sanitizingURLs()
            if cleanPrev.semanticallyEqualForSync(to: d) {
                // Reuse the stable bytes (preserving advisory URLs + the ORIGINAL
                // publisher's origin), but back-fill origin once if the stored record
                // predates origin stamping and this device knows it — a one-time
                // re-publish that then re-stabilizes.
                var merged = cleanPrev
                if merged.originDeviceName == nil, d.originDeviceName != nil {
                    merged.originDeviceName = d.originDeviceName
                    merged.originDeviceKind = d.originDeviceKind
                }
                return CanonicalJSON.encode(merged)
            }
            // Meaningful fields changed (e.g. a rename) → publish the new descriptor,
            // but keep the ORIGINAL publisher's origin rather than overwriting it with
            // the editing device.
            var out = d
            if cleanPrev.originDeviceName != nil {
                out.originDeviceName = cleanPrev.originDeviceName
                out.originDeviceKind = cleanPrev.originDeviceKind
            }
            return CanonicalJSON.encode(out)
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
        var removed = RemovedAccountsStore()
        removed.removeAll()
        refreshPendingSyncedServers()
    }

    /// The household's FULL server descriptor set: this device's signed-in accounts
    /// PLUS the descriptors it has synced but isn't signed into (pending). Including
    /// the pending ones is essential — otherwise a device would omit them from its
    /// snapshot and DELETE another device's servers for the whole household.
    static func mergedAccountDescriptors(signedIn accounts: [Account]) -> [SyncedAccountDescriptor] {
        var byID: [String: SyncedAccountDescriptor] = [:]
        for d in PendingSyncedServersStore().all { byID[d.id] = d.sanitizingURLs() }
        // Stamp this Apple TV as the origin of its own signed-in servers so peers can
        // show "Set up with <this TV>". Preserved across re-publish (origin is excluded
        // from semanticallyEqualForSync), so it names the ORIGIN device.
        let originName = DeviceDisplayName.current(fallback: "Apple TV")
        for a in accounts {
            byID[a.id] = SyncedAccountDescriptor(account: a).stampingOrigin(name: originName, kind: "tv") // signed-in wins
        }
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
        var removalUpserts: [String: Int] = [:]
        var removalClears: Set<String> = []

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
            case .removal:
                if let value, let dto = CanonicalJSON.decode(AccountRemovalDTO.self, from: value) {
                    removalUpserts[key.id] = dto.removedAtEpoch
                } else if value == nil {
                    removalClears.insert(key.id)
                }
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
                // A queued setup prompt for a now-removed server must not linger — the
                // user could otherwise accept it and undo the removal.
                if cloudSyncUI.pendingServerPrompt?.id == id { cloudSyncUI.pendingServerPrompt = nil }
                if accountsProviders.accounts.contains(where: { $0.id == id }) {
                    removeAccount(id: id)
                }
            }
            for id in removalClears { removed.clear(id) }
        }

        // 1. Profiles: cosmetic upserts + deletions (default never deleted).
        // Accounts this device KNOWS aren't Plex. Synced ids for servers not
        // signed in here have an unknown provider, and are deliberately treated
        // as possibly-Plex — see `noteIdentityQuestions`.
        let knownNonPlexAccountIDs = Set(
            accountsProviders.accounts
                .filter { $0.server.provider != .plex }
                .map(\.id)
        )
        // Which profiles this device had BEFORE applying the upserts, so the
        // backfill below can tell a genuine first arrival from a cosmetic update
        // to one we already knew. Backfilling on every upsert would re-record
        // questions the user has already answered — or declined — and a remote
        // rename would silently re-gate their imports.
        let knownProfileIDs = Set(profilesModel.profiles.map(\.id))
        // Captured BEFORE anything is applied: a synced delete of the ACTIVE
        // Kids Profile re-points the selection with no user action, and the
        // parental gate can only tell that happened if it knows where we were.
        let outgoingProfile = profilesModel.activeProfile
        if !profileUpserts.isEmpty || !profileDeletes.isEmpty {
            for profileID in profileDeletes
            where profileID != ProfileStore.defaultProfileID {
                removeMediaAliases(forProfileID: profileID)
            }
            profilesModel.applySyncedProfileDTOs(profileUpserts, deletions: profileDeletes)
            // A profile can arrive in a LATER batch than its membership, so that
            // membership was applied with no profile to record the identity
            // question against — and being already persisted, an identical later
            // sync shows nothing newly enabled and never asks. Backfill on
            // arrival; a profile new to this device is exactly one nobody here
            // has been asked about.
            for dto in profileUpserts where !knownProfileIDs.contains(dto.key) {
                profilesModel.noteIdentityQuestionsForArrivedProfile(
                    dto.key,
                    knownNonPlexAccountIDs: knownNonPlexAccountIDs
                )
            }
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
            // Applied through the shared path so a server the SYNC switches on
            // asks who you are there, exactly as the local toggle does — see
            // `applySyncedMembership`. Without it a profile set up correctly on
            // one device inherits the account owner's watchlist on another.
            for (pid, ids) in membershipSet {
                profilesModel.applySyncedMembership(
                    ids,
                    forProfile: pid,
                    knownNonPlexAccountIDs: knownNonPlexAccountIDs
                )
            }
            for pid in membershipClear { profilesModel.clearActiveAccountIDs(for: pid) }
        }
        // 4. Descriptors → pending "needs sign-in" servers.
        if descriptorsTouched { refreshPendingSyncedServers() }

        rebuildSettingsModels()
        // A remote change can make a DIFFERENT profile active — a peer deleting
        // the one we were on falls back to `profiles.first` — and it can also
        // deliver a lock onto the profile we're already sitting in. Re-check the
        // gate so neither ends with an unlocked view of a locked profile.
        profileFlow.enforceLockOnActiveProfile(leaving: outgoingProfile)
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
        // Household-removed (tombstoned) servers are hidden here and never prompted.
        let removedIDs = RemovedAccountsStore().removedIDs
        if let prompt = cloudSyncUI.pendingServerPrompt, removedIDs.contains(prompt.id) {
            cloudSyncUI.pendingServerPrompt = nil
        }
        let newly = store.newlyPending(excludingLocal: localIDs).filter { !removedIDs.contains($0.id) }
        cloudSyncUI.pendingSyncedServers = store.pending(excludingLocal: localIDs)
            .filter { !removedIDs.contains($0.id) }
        if SyncSetupFeatureFlag().isEnabled, cloudSyncUI.pendingServerPrompt == nil,
           let first = newly.first {
            cloudSyncUI.pendingServerPrompt = first
            store.markPrompted(newly.map(\.id))
        }
    }

    /// Whether the delete UI should offer the "Everywhere" vs "This device" choice —
    /// simply whether cross-device sync is on. The destructive "Everywhere" action has
    /// its own second confirm, so we don't gate on live device detection (which lags).
    public var offersRemoveEverywhere: Bool { SyncSetupFeatureFlag().isEnabled }

    /// Whether the user has other devices on this iCloud account.
    public var hasOtherHouseholdDevices: Bool {
        !HouseholdDevicesStore().otherDevices(excluding: accountsProviders.accountStore.deviceID()).isEmpty
    }

    /// Register this Apple TV in the household presence registry.
    func heartbeatHouseholdPresence() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        HouseholdDevicesStore().heartbeat(
            deviceID: accountsProviders.accountStore.deviceID(),
            deviceName: DeviceDisplayName.current(fallback: "Apple TV"))
    }

    /// Remove a server from EVERY device on this iCloud account: publish a removal
    /// tombstone so peers sign it out and stop re-publishing it, remove it here, and
    /// push the change now. Reversible by re-adding the server anywhere.
    public func removeAccountEverywhere(id: String) {
        var removed = RemovedAccountsStore()
        removed.markRemoved(id, at: Int(Date().timeIntervalSince1970))
        var pending = PendingSyncedServersStore()
        pending.removeSynced(id)
        removeAccount(id: id)   // local removal (also retires credentials)
        refreshPendingSyncedServers()
        scheduleCloudPublish()  // propagate the tombstone + delete the descriptor
    }

    /// Clear any household-removal tombstone for an account the user just (re)added, so
    /// its descriptor syncs again and peers stop treating it as removed.
    public func clearRemovalTombstone(for id: String) {
        var removed = RemovedAccountsStore()
        guard removed.isRemoved(id) else { return }
        removed.clear(id)
        scheduleCloudPublish()
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
        // Never start a real CloudKit engine inside a unit-test host. xctest runs
        // without the app's iCloud entitlement, so CloudKit traps (SIGTRAP) the
        // moment the container is touched — which kills the whole test process and
        // silently drops every remaining test in the bundle. The flag defaults ON
        // when unset, and a test host's UserDefaults is always unset, so every test
        // that reached `bootstrap()` hit this.
        guard !Self.isRunningUnitTests else { return }
        guard cloudSync != nil else {
            PlozzLog.sync.error("CloudSync: no writable state dir — sync unavailable")
            return
        }
        let config = cloudSync
        Task {
            await config?.activate()
        }
        armCloudConfigObservation()
        heartbeatHouseholdPresence()
        checkForSyncSetupOffer()
        startSyncSetupOfferPolling()
    }

    /// True when this process is an XCTest host. `XCTestConfigurationFilePath` is
    /// set by the test runner for both app-hosted and library tests, and is absent
    /// in the shipping app.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
    public func scheduleCloudPublish() {
        guard SyncSetupFeatureFlag().isEnabled,
              cloudSync != nil else {
            return
        }
        let config = cloudSync
        cloudPublishTask?.cancel()
        cloudPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            PlozzLog.sync.info("CloudSync: local config changed — publishing")
            await config?.publishLocalChanges()
            _ = self
        }
    }

    /// Turn cross-device Sync & Setup on/off. Enabling activates CloudKit sync and
    /// starts observing; disabling stops publishing but NEVER deletes the shared
    /// cloud config (other devices keep syncing).
    public func setSyncSetupEnabled(_ on: Bool) {
        syncSetup.setEnabled(on)
        let config = cloudSync
        guard let config else { return }
        if on {
            Task {
                await config.activate()
            }
            armCloudConfigObservation()
            scheduleCloudPublish()
            heartbeatHouseholdPresence()
            startSyncSetupOfferPolling()
        } else {
            HouseholdDevicesStore().remove(deviceID: accountsProviders.accountStore.deviceID())
            syncSetupOfferPollTask?.cancel()
            syncSetupOfferPollTask = nil
            cloudSyncUI.pendingSyncSetupOffer = nil
            Task { await config.deactivate() }
        }
    }

    func prepareMediaAliasLedger() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.mediaAliasLedger.loadProfiles(
                    self.profilesModel.profiles.map(\.id)
                )
                try await self.mediaAliasLedger.activate(
                    profileID: self.profilesModel.activeProfileID
                )
                await self.prepareUniversalWatchlist()
            } catch {
                PlozzLog.sync.error(
                    "Media aliases: local ledger preparation failed: \(error.localizedDescription)"
                )
            }
            self.armMediaAliasObservation()
            self.armMediaStateSnapshotObservation()
        }
    }

    /// Profile roster/selection changes require activation and one native import.
    /// Ordinary alias/watchlist snapshot mutations are observed separately below;
    /// they must never re-enter preparation or fetch provider watchlists.
    func armMediaAliasObservation() {
        withObservationTracking {
            _ = profilesModel.profiles
            _ = profilesModel.activeProfileID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.mediaAliasLedger.loadProfiles(
                        self.profilesModel.profiles.map(\.id)
                    )
                    try await self.mediaAliasLedger.activate(
                        profileID: self.profilesModel.activeProfileID
                    )
                    await self.prepareUniversalWatchlist()
                } catch {
                    PlozzLog.sync.error(
                        "Media aliases: profile activation failed: \(error.localizedDescription)"
                    )
                }
                self.scheduleCloudPublish()
                self.armMediaAliasObservation()
            }
        }
    }

    func armMediaStateSnapshotObservation() {
        withObservationTracking {
            _ = mediaAliasLedger.snapshotsByProfile
            _ = universalWatchlist.snapshotsByProfile
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleCloudPublish()
                self.armMediaStateSnapshotObservation()
            }
        }
    }

    func removeMediaAliases(forProfileID profileID: String) {
        removeUniversalWatchlist(forProfileID: profileID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.mediaAliasLedger.removeProfile(profileID)
                await self.cloudSync?.publishLocalChanges()
            } catch {
                PlozzLog.sync.error(
                    "Media aliases: profile removal failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func captureMediaStateSyncRecords(
        fallback: [SyncRecordID: Data]
    ) async -> [SyncRecordID: Data] {
        do {
            var captured = try await mediaAliasLedger.captureAllAliasSyncRecords(
                profileIDs: profilesModel.profiles.map(\.id),
                fallback: fallback
            )
            for profile in profilesModel.profiles {
                try universalWatchlist.hydrate(profileID: profile.id)
                captured.merge(
                    try universalWatchlist.captureSyncRecords(
                        profileID: profile.id,
                        fallback: fallback
                    ),
                    uniquingKeysWith: { _, watchlist in watchlist }
                )
            }
            return captured
        } catch {
            PlozzLog.sync.error(
                "Media aliases: capture failed; preserving sync baseline: \(error.localizedDescription)"
            )
            return fallback
        }
    }

    func applyMediaStateSyncRecords(_ changes: SyncLocalChanges) async {
        var parsed: [MediaAliasRemoteChange] = []
        var watchlistChanges:
            [String: [WatchlistMediaStateRecordKey: Data]] = [:]
        var invalidNameCount = 0
        for (recordName, value) in changes {
            if let key = MediaStateRecordKey.parse(recordName) {
                parsed.append(MediaAliasRemoteChange(key: key, value: value))
            } else if let key = WatchlistMediaStateRecordKey.parse(recordName) {
                if let value {
                    watchlistChanges[key.profileID, default: [:]][key] = value
                }
            } else {
                invalidNameCount += 1
            }
        }
        if invalidNameCount > 0 {
            PlozzLog.sync.error(
                "Media aliases: rejected \(invalidNameCount) invalid record name(s)"
            )
        }
        do {
            let report = try await mediaAliasLedger.applyRemoteChanges(parsed)
            if !report.rejectedRecordNames.isEmpty {
                PlozzLog.sync.error(
                    "Media aliases: rejected \(report.rejectedRecordNames.count) malformed record(s)"
                )
            }
        } catch {
            PlozzLog.sync.error("Media aliases: remote apply failed")
        }

        var appliedWatchlistCount = 0
        var rejectedWatchlistCount = 0
        var ignoredDeletedProfileCount = 0
        for profileID in watchlistChanges.keys.sorted() {
            guard let records = watchlistChanges[profileID] else { continue }
            do {
                let report = try universalWatchlist.applyRemoteSyncRecords(
                    profileID: profileID,
                    changes: records
                )
                appliedWatchlistCount += report.appliedCount
                rejectedWatchlistCount += report.rejectedCount
                ignoredDeletedProfileCount +=
                    report.ignoredDeletedProfileRecordNames.count
                if report.appliedCount > 0 {
                    try universalWatchlist.reconcileAliases(
                        profileID: profileID,
                        aliasSnapshot:
                            mediaAliasLedger.snapshotsByProfile[profileID]
                                ?? .empty
                    )
                }
            } catch {
                rejectedWatchlistCount += records.count
            }
        }
        if rejectedWatchlistCount > 0 || ignoredDeletedProfileCount > 0 {
            PlozzLog.sync.error(
                "Watchlist sync rejected=\(rejectedWatchlistCount) ignoredDeletedProfile=\(ignoredDeletedProfileCount)"
            )
        }
        if appliedWatchlistCount > 0 {
            // Through the host, so the memoized membership set is dropped with
            // it: a remote removal that leaves the active count where it was is
            // otherwise invisible to that memo's revision key.
            announceUniversalWatchlistDidChange()
        }
    }
}
