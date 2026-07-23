import Foundation

// MARK: - Removed-account tombstones (household-wide "Remove Everywhere")
//
// When the user chooses "Remove Everywhere" for a server, we can't just delete its
// descriptor from iCloud — another device that still holds the account would simply
// re-publish it. Instead we publish a small, NON-SECRET tombstone (accountID +
// when) that every device honors: it signs the account out (if present), hides it
// from the pending "servers from your other devices" list, and stops re-publishing
// its descriptor. Re-adding the same server anywhere clears the tombstone.
//
// The marker is device-local persisted state (mirrored from the synced `.removal`
// records) so `captureSyncRecords` reproduces byte-identical removal records on
// re-capture — preserving the sync round-trip invariant.

/// The synced payload of a removal tombstone. Small and non-secret by construction.
public struct AccountRemovalDTO: Codable, Hashable, Sendable {
    public var accountID: String
    /// Epoch seconds when the removal was issued. Stored/reproduced verbatim so the
    /// synced record round-trips; also lets the UI show when a server was removed.
    public var removedAtEpoch: Int

    public init(accountID: String, removedAtEpoch: Int) {
        self.accountID = accountID
        self.removedAtEpoch = removedAtEpoch
    }
}

/// Device-local store of removal tombstones, keyed by account id. Persisted in
/// `UserDefaults`; mirrors the synced `.removal` records so capture is deterministic.
public struct RemovedAccountsStore: Sendable {
    public static let storageKey = "com.plozz.syncSetup.removedAccounts.v1"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// All current tombstones as accountID → removedAtEpoch.
    public var all: [String: Int] {
        (defaults.dictionary(forKey: Self.storageKey) as? [String: Int]) ?? [:]
    }

    /// The set of account ids currently tombstoned (removed household-wide).
    public var removedIDs: Set<String> { Set(all.keys) }

    public func isRemoved(_ id: String) -> Bool { all[id] != nil }

    /// Record a removal for `id` at `epoch`. On APPLY this stores the received
    /// record's epoch verbatim so a re-capture reproduces byte-identical removal
    /// bytes (the sync round-trip invariant) — overwriting, never min/max, which would
    /// re-derive different bytes and clobber the peer. Idempotent for a duplicate
    /// delivery (same epoch → same value).
    public mutating func markRemoved(_ id: String, at epoch: Int) {
        var map = all
        map[id] = epoch
        defaults.set(map, forKey: Self.storageKey)
    }

    /// Clear the tombstone for `id` (the server was re-added, locally or on a peer).
    public mutating func clear(_ id: String) {
        var map = all
        guard map[id] != nil else { return }
        map[id] = nil
        defaults.set(map, forKey: Self.storageKey)
    }

    /// Wipe all tombstones (used on iCloud account switch / debug reset).
    public mutating func removeAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
