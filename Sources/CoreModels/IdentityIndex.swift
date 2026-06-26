import Foundation

/// A lean, persistable **membership** fact: that one title lives on one server
/// under *that server's* own item id. This is the atom the ``IdentityIndex`` keeps
/// per ``MediaIdentity`` — exactly enough to (a) build a ``MediaSourceRef`` for the
/// detail server-picker and (b) build a ``WatchMutationTarget`` for the watch
/// fan-out, so **one** resolved-source set drives both.
///
/// It deliberately omits live watch-state and versions. Membership ("which
/// servers hold this title") changes only when a library is re-scanned or an
/// account is added/removed, whereas resume/played change on every play — folding
/// live watch-state into the index would make it constantly stale. Watch-state is
/// therefore still folded live from the loaded rows (``MediaItemMerger`` /
/// ``UnifiedWatchState``); the index only contributes the **server set**.
public struct IndexedSource: Hashable, Sendable, Codable {
    /// The owning `Account.id`.
    public var accountID: String
    /// **This server's** local id for the title (Jellyfin item id / Plex ratingKey).
    public var itemID: String
    /// The backend kind — labels the picker and routes future per-backend logic.
    public var providerKind: ProviderKind?
    /// Friendly server name for the picker, when known.
    public var serverName: String?
    /// Friendly signed-in user name for the picker, when known.
    public var accountName: String?
    /// The catalogue kind the entry was indexed as (movie / series). Lets episode
    /// expansion ask the index only for series membership.
    public var kind: MediaItemKind

    public init(
        accountID: String,
        itemID: String,
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        kind: MediaItemKind = .unknown
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.kind = kind
    }

    /// Stable identity: a title appears at most once per (account, item) pair.
    public var id: String { "\(accountID):\(itemID)" }

    /// The fan-out target addressing this server's copy of the title.
    public var target: WatchMutationTarget {
        WatchMutationTarget(accountID: accountID, itemID: itemID, providerKind: providerKind)
    }

    /// A membership-only ``MediaSourceRef`` for the picker / merge enrichment.
    /// Versions and watch-state are intentionally empty — they're filled live by
    /// the loaded rows / a detail fetch, never by the index.
    public var sourceRef: MediaSourceRef {
        MediaSourceRef(
            accountID: accountID,
            itemID: itemID,
            providerKind: providerKind,
            serverName: serverName,
            accountName: accountName
        )
    }
}

/// An immutable, value-typed view of the ``IdentityIndex`` at a point in time —
/// the **single shared source of truth** every synchronous surface reads.
///
/// `AppState` publishes a fresh snapshot whenever the index rebuilds; Home rows,
/// aggregated Library browse, Search, the detail server-picker and the watch
/// fan-out all resolve a title's full cross-server/cross-account source set by an
/// O(1) lookup here instead of recomputing it per entry path. Being a plain
/// `Sendable` value it can be read on the main actor, captured into the pure merge
/// core, or handed to a background reconciler with no locking.
///
/// When the index is cold (no account warmed yet) the snapshot is ``empty`` and
/// every lookup returns `[]`, so callers degrade gracefully to their existing
/// on-demand resolution — the index only ever *adds* known sources, never removes
/// a caller's own, so a write is never dropped while warming.
public struct IdentityIndexSnapshot: Sendable, Equatable {
    /// A warm but empty snapshot — used before any account has been indexed.
    public static let empty = IdentityIndexSnapshot(byIdentity: [:])

    /// identity → its sources, de-duplicated by `IndexedSource.id` and kept in a
    /// stable (sorted) order so lookups are deterministic across rebuilds.
    private let byIdentity: [MediaIdentity: [IndexedSource]]

    public init(byIdentity: [MediaIdentity: [IndexedSource]]) {
        self.byIdentity = byIdentity.mapValues { sources in
            sources.sorted { $0.id < $1.id }
        }
    }

    public var isEmpty: Bool { byIdentity.isEmpty }

    /// The number of distinct identities indexed — diagnostics only.
    public var identityCount: Int { byIdentity.count }

    /// Every indexed source for `identities`, unioned across all of them and
    /// de-duplicated by `(account,item)`, in stable order. The union is what makes
    /// a title's set **origin-agnostic**: the same answer whether it was reached
    /// from a Plex or a Jellyfin card.
    public func sources(forIdentities identities: [MediaIdentity]) -> [IndexedSource] {
        guard !identities.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [IndexedSource] = []
        for identity in identities {
            guard let sources = byIdentity[identity] else { continue }
            for source in sources where seen.insert(source.id).inserted {
                result.append(source)
            }
        }
        return result
    }

    /// Every indexed source for `item`, by its ``MediaItemIdentity`` identities.
    public func sources(for item: MediaItem) -> [IndexedSource] {
        sources(forIdentities: MediaItemIdentity.identities(for: item))
    }

    /// Membership ``MediaSourceRef``s for `item` — the picker / merge-enrichment view.
    public func sourceRefs(for item: MediaItem) -> [MediaSourceRef] {
        sources(for: item).map(\.sourceRef)
    }

    /// The complete watch fan-out target set for `item`, from the index alone.
    public func targets(for item: MediaItem) -> [WatchMutationTarget] {
        sources(for: item).map(\.target)
    }
}

/// The **eager identity index**: an `identity → sources` map populated up front
/// when accounts enroll and libraries sync, so any title resolves its full
/// cross-server / cross-account set by O(1) lookup instead of two divergent,
/// per-entry-path computations (Home-load merge vs detail-time resolve).
///
/// Storage is partitioned **per account** (`account → identity → source`) so an
/// account sign-out or re-scan is a single-key replace with no cross-account
/// rebuild, and ``snapshot()`` simply folds the buckets into one identity map.
/// The actor isolates all mutation; readers consume immutable ``IdentityIndexSnapshot``s.
///
/// Freshness is tracked per account (``isWarm(_:)`` / ``builtAt(_:)``); a caller
/// re-warms a stale account incrementally. Nothing here ever blocks a watch: until
/// an account is warm its lookups are simply absent, and callers fall back to
/// their existing on-demand discovery.
public actor IdentityIndex {
    /// account → identity → (sourceID → source).
    private var byAccount: [String: [MediaIdentity: [String: IndexedSource]]] = [:]
    /// Accounts whose initial catalogue scan has completed at least once.
    private var warmAccounts: Set<String> = []
    /// When each account's catalogue was last (re)built, for staleness checks.
    private var builtAtByAccount: [String: Date] = [:]
    private let now: @Sendable () -> Date

    public init(now: @Sendable @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Folds every account's bucket into one identity → sources map. Cheap enough
    /// to call after each account finishes warming so readers see progress early.
    public func snapshot() -> IdentityIndexSnapshot {
        var merged: [MediaIdentity: [IndexedSource]] = [:]
        for (_, identityMap) in byAccount {
            for (identity, sourcesByID) in identityMap {
                merged[identity, default: []].append(contentsOf: sourcesByID.values)
            }
        }
        return IdentityIndexSnapshot(byIdentity: merged)
    }

    /// Indexes a freshly fetched page of catalogue `items` for `accountID`,
    /// labelling each source with the account's server/user info. Only
    /// **movies and series** carry a stable cross-server identity; seasons,
    /// episodes and folders are skipped (episode membership is derived from the
    /// series at fan-out time via a children-walk, never indexed directly).
    public func ingest(
        _ items: [MediaItem],
        accountID: String,
        serverInfo: SourceServerInfo? = nil
    ) {
        guard !items.isEmpty else { return }
        var bucket = byAccount[accountID] ?? [:]
        for item in items {
            guard item.kind == .movie || item.kind == .series else { continue }
            let identities = MediaItemIdentity.identities(for: item)
            guard !identities.isEmpty else { continue }
            let source = IndexedSource(
                accountID: accountID,
                itemID: item.id,
                providerKind: serverInfo?.providerKind,
                serverName: serverInfo?.serverName,
                accountName: serverInfo?.accountName,
                kind: item.kind
            )
            for identity in identities {
                bucket[identity, default: [:]][source.id] = source
            }
        }
        byAccount[accountID] = bucket
    }

    /// Clears `accountID`'s bucket so a full re-scan replaces it cleanly. Marks the
    /// account not-warm until ``finishRebuild(for:)`` is called.
    public func beginRebuild(for accountID: String) {
        byAccount[accountID] = [:]
        warmAccounts.remove(accountID)
    }

    /// Marks `accountID`'s scan complete and records its freshness timestamp.
    public func finishRebuild(for accountID: String) {
        warmAccounts.insert(accountID)
        builtAtByAccount[accountID] = now()
    }

    /// Drops an account entirely (sign-out / profile switch), so its sources stop
    /// appearing in the snapshot immediately.
    public func removeAccount(_ accountID: String) {
        byAccount[accountID] = nil
        warmAccounts.remove(accountID)
        builtAtByAccount[accountID] = nil
    }

    /// Prunes any indexed account not in `accountIDs` (e.g. after a profile switch
    /// narrows the active set), keeping the snapshot honest.
    public func retainAccounts(_ accountIDs: Set<String>) {
        for accountID in byAccount.keys where !accountIDs.contains(accountID) {
            removeAccount(accountID)
        }
    }

    /// Whether `accountID`'s catalogue has been scanned at least once.
    public func isWarm(_ accountID: String) -> Bool { warmAccounts.contains(accountID) }

    /// When `accountID` was last (re)built, or `nil` if never.
    public func builtAt(_ accountID: String) -> Date? { builtAtByAccount[accountID] }

    /// Accounts that are warm but older than `ttl`, so a caller can re-warm them
    /// incrementally without rebuilding fresh ones.
    public func staleAccounts(olderThan ttl: TimeInterval) -> Set<String> {
        let cutoff = now().addingTimeInterval(-ttl)
        return warmAccounts.filter { (builtAtByAccount[$0] ?? .distantPast) < cutoff }
    }
}

/// A small, thread-safe holder for the latest ``IdentityIndexSnapshot`` so a
/// `@Sendable` lookup closure can read the current source-of-truth from any actor
/// or detached task (Home aggregation, search dedupe and the off-main player stop
/// hook all run off the main actor). `AppState` publishes into it as the index
/// warms; readers always see the most recent value with no `await`.
public final class IdentityIndexSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: IdentityIndexSnapshot

    public init(_ snapshot: IdentityIndexSnapshot = .empty) {
        self.snapshot = snapshot
    }

    /// The current snapshot.
    public var current: IdentityIndexSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Atomically replaces the held snapshot.
    public func update(_ snapshot: IdentityIndexSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }

    /// A `@Sendable` identity-sources lookup over the live snapshot, suitable for
    /// the ``MediaItemMerger`` enrichment seam and the watch fan-out.
    public func sourcesProvider() -> @Sendable (MediaItem) -> [MediaSourceRef] {
        { [weak self] item in self?.current.sourceRefs(for: item) ?? [] }
    }
}
