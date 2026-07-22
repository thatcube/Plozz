import Foundation

// MARK: - Pending synced servers (device-local)
//
// When CloudKit syncs the household's server DESCRIPTORS to this device, some may
// be servers this device has no local credential for (very common on the Apple TV,
// which can't inherit logins over iCloud). Those are NOT real accounts — the app's
// account pipeline assumes a usable, signed-in account — so we keep them in this
// separate, device-local store and surface them as "Needs sign-in" entries the
// user can set up (via pairing / native sign-in), ignore, or delete.
//
// Purely local: this never syncs (it's per-device state about what THIS device has
// yet to act on). It holds only NON-SECRET descriptors (no tokens, by construction).

/// Tracks synced server descriptors this device hasn't signed into yet, plus which
/// ones the user chose to ignore, persisted per-device in `UserDefaults`.
public struct PendingSyncedServersStore: Sendable {
    public static let storageKey = "com.plozz.syncSetup.pendingServers.v1"
    public static let ignoredKey = "com.plozz.syncSetup.ignoredServers.v1"
    /// Ids we've already surfaced a prompt for, so a device is nudged only once per server.
    public static let promptedKey = "com.plozz.syncSetup.promptedServers.v1"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The descriptors currently awaiting sign-in on this device (non-ignored).
    public var pending: [SyncedAccountDescriptor] {
        let ignored = ignoredIDs
        return storedDescriptors.filter { !ignored.contains($0.id) }
    }

    /// All descriptors we've recorded (including ignored ones), for a full listing.
    public var all: [SyncedAccountDescriptor] { storedDescriptors }

    public var ignoredIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    /// Reconcile the incoming synced descriptors against the accounts this device
    /// already has. Descriptors whose id matches a local account are dropped (this
    /// device is signed in); the rest are recorded as pending. Returns the ids that
    /// are NEWLY pending and not yet prompted, so the caller can offer to set them up.
    @discardableResult
    public mutating func reconcile(
        syncedDescriptors: [SyncedAccountDescriptor],
        localAccountIDs: Set<String>
    ) -> [SyncedAccountDescriptor] {
        // Keep only descriptors this device isn't signed into.
        let unauthorized = syncedDescriptors.filter { !localAccountIDs.contains($0.id) }
        // Drop any previously-pending descriptor that has since been signed into or
        // removed from the household (no longer in the synced set).
        let syncedIDs = Set(syncedDescriptors.map(\.id))
        var kept = unauthorized
        // Preserve prior ordering stability by id.
        kept.sort { $0.id < $1.id }
        store(kept)

        // Prune bookkeeping for descriptors that vanished from the household.
        pruneSets(toKeep: syncedIDs)

        // New = pending, not ignored, not already prompted.
        let ignored = ignoredIDs
        let prompted = promptedIDs
        return kept.filter { !ignored.contains($0.id) && !prompted.contains($0.id) }
    }

    public mutating func ignore(_ id: String) {
        var ids = ignoredIDs
        ids.insert(id)
        defaults.set(Array(ids), forKey: Self.ignoredKey)
    }

    /// Upsert one synced descriptor (V3 per-record apply). The full synced set is kept
    /// so `pending(excludingLocal:)` can recompute the needs-sign-in list from deltas.
    public mutating func upsertSynced(_ descriptor: SyncedAccountDescriptor) {
        var all = Dictionary(uniqueKeysWithValues: storedDescriptors.map { ($0.id, $0) })
        all[descriptor.id] = descriptor
        store(all.values.sorted { $0.id < $1.id })
    }

    /// Remove one synced descriptor (its record was deleted from the household).
    public mutating func removeSynced(_ id: String) {
        var all = Dictionary(uniqueKeysWithValues: storedDescriptors.map { ($0.id, $0) })
        all[id] = nil
        store(all.values.sorted { $0.id < $1.id })
        unignore(id)
    }

    /// The needs-sign-in list: synced descriptors this device isn't signed into and
    /// hasn't ignored.
    public func pending(excludingLocal localAccountIDs: Set<String>) -> [SyncedAccountDescriptor] {
        let ignored = ignoredIDs
        return storedDescriptors
            .filter { !localAccountIDs.contains($0.id) && !ignored.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    /// Descriptors newly needing sign-in that haven't been prompted yet, for the
    /// one-time "adopt these servers" nudge.
    public func newlyPending(excludingLocal localAccountIDs: Set<String>) -> [SyncedAccountDescriptor] {
        let prompted = promptedIDs
        return pending(excludingLocal: localAccountIDs).filter { !prompted.contains($0.id) }
    }

    public mutating func unignore(_ id: String) {
        var ids = ignoredIDs
        ids.remove(id)
        defaults.set(Array(ids), forKey: Self.ignoredKey)
    }

    /// Mark ids as prompted so they aren't nudged again.
    public mutating func markPrompted(_ ids: [String]) {
        var set = promptedIDs
        ids.forEach { set.insert($0) }
        defaults.set(Array(set), forKey: Self.promptedKey)
    }

    /// Forget a descriptor entirely (e.g. the user deleted it). It'll reappear only
    /// if the household re-adds it and it syncs again.
    public mutating func forget(_ id: String) {
        store(storedDescriptors.filter { $0.id != id })
        unignore(id)
    }

    public var promptedIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.promptedKey) ?? [])
    }

    // MARK: Storage

    private var storedDescriptors: [SyncedAccountDescriptor] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SyncedAccountDescriptor].self, from: data)
        else { return [] }
        return decoded
    }

    private func store(_ descriptors: [SyncedAccountDescriptor]) {
        if let data = try? JSONEncoder().encode(descriptors) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private mutating func pruneSets(toKeep: Set<String>) {
        let prunedIgnored = ignoredIDs.intersection(toKeep)
        defaults.set(Array(prunedIgnored), forKey: Self.ignoredKey)
        let prunedPrompted = promptedIDs.intersection(toKeep)
        defaults.set(Array(prunedPrompted), forKey: Self.promptedKey)
    }
}
