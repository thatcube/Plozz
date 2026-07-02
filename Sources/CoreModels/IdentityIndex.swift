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
    /// How reachable this source's server is from the device (same-LAN vs
    /// remote/Tailscale), so an index-only membership fact still steers
    /// best-source selection toward the local copy. `nil` when unclassified.
    public var locality: SourceLocality?
    /// The catalogue kind the entry was indexed as (movie / series). Lets episode
    /// expansion ask the index only for series membership.
    public var kind: MediaItemKind

    public init(
        accountID: String,
        itemID: String,
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        locality: SourceLocality? = nil,
        kind: MediaItemKind = .unknown
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.locality = locality
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
            accountName: accountName,
            locality: locality
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

    /// Diagnostics only: how many indexed identities have sources on **more than
    /// one account** (a genuine cross-server union). When this is `0` while accounts
    /// are warm, the index holds only origin-local memberships — so a watch can
    /// never fan out, no matter the entry path (the H1 / "index didn't warm a
    /// union" bug class).
    public var crossServerIdentityCount: Int {
        byIdentity.values.reduce(into: 0) { count, sources in
            if Set(sources.map(\.accountID)).count > 1 { count += 1 }
        }
    }

    /// Diagnostics only: every distinct `Account.id` that contributed at least one
    /// indexed source. Lets the fan-out readout show which accounts actually warmed.
    public var indexedAccountIDs: Set<String> {
        var ids = Set<String>()
        for sources in byIdentity.values {
            for source in sources { ids.insert(source.accountID) }
        }
        return ids
    }

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

    /// Every indexed source for `item`, by its ``MediaItemIdentity`` identities,
    /// **scoped to the item's kind**. TMDb/TVDb reuse the same integer id across
    /// movies and series (movie 550 ≠ tv 550), and `identities(for:)` emits bare,
    /// kind-less external ids — so an unscoped lookup would fold a same-id series
    /// into a movie's source set (and vice-versa), polluting the picker and
    /// letting best-source selection route playback to the wrong work. Restricting
    /// to sources indexed under the *same kind* keeps enrichment correct; episode
    /// expansion asks for series membership through the series probe, not here.
    public func sources(for item: MediaItem) -> [IndexedSource] {
        let kind = item.kind
        return sources(forIdentities: MediaItemIdentity.identities(for: item))
            .filter { $0.kind == kind }
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
                locality: serverInfo?.locality,
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

    /// Exports the **warm** account buckets as a flat, JSON-friendly value for disk
    /// persistence. Only conclusively-built accounts are exported so a half-scanned
    /// account is never frozen as authoritative; the live scan re-derives it next
    /// launch. Each entry pairs an identity with the membership source under it, so
    /// loading can rebuild the `identity → source` buckets without re-deriving
    /// identities (and without a JSON-unfriendly enum-keyed dictionary).
    public func export() -> PersistedIdentityIndex {
        var entriesByAccount: [String: [PersistedIdentityIndex.Entry]] = [:]
        for (accountID, identityMap) in byAccount where warmAccounts.contains(accountID) {
            var entries: [PersistedIdentityIndex.Entry] = []
            for (identity, sourcesByID) in identityMap {
                for source in sourcesByID.values {
                    entries.append(PersistedIdentityIndex.Entry(identity: identity, source: source))
                }
            }
            entriesByAccount[accountID] = entries
        }
        let builtAt = builtAtByAccount.filter { warmAccounts.contains($0.key) }
        return PersistedIdentityIndex(entriesByAccount: entriesByAccount, builtAtByAccount: builtAt)
    }

    /// Seeds the index from a persisted snapshot at launch so cross-server unions
    /// exist at **t=0** — the first post-boot stop fans out to every server instead
    /// of origin-only while the live scan runs. Restored accounts are marked warm
    /// with their **persisted** `builtAt`, so a stale one still re-warms on the
    /// normal TTL path while a recently-persisted one is simply reused.
    ///
    /// - Only accounts in `retaining` are restored (**prune on load**): a server
    ///   removed / a profile switched between launches is never resurrected.
    /// - An account already populated in memory (a live scan won the race) is left
    ///   untouched — disk never clobbers fresher live data.
    /// - Returns `true` if at least one account was restored, so the caller can
    ///   publish a snapshot immediately.
    @discardableResult
    public func restore(from persisted: PersistedIdentityIndex, retaining accountIDs: Set<String>) -> Bool {
        var restoredAny = false
        for (accountID, entries) in persisted.entriesByAccount {
            guard accountIDs.contains(accountID) else { continue }
            guard byAccount[accountID]?.isEmpty ?? true, !warmAccounts.contains(accountID) else { continue }
            var bucket: [MediaIdentity: [String: IndexedSource]] = [:]
            for entry in entries {
                bucket[entry.identity, default: [:]][entry.source.id] = entry.source
            }
            guard !bucket.isEmpty else { continue }
            byAccount[accountID] = bucket
            warmAccounts.insert(accountID)
            builtAtByAccount[accountID] = persisted.builtAtByAccount[accountID] ?? .distantPast
            restoredAny = true
        }
        return restoredAny
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

/// Population-time **identity enrichment** so the index is genuinely complete,
/// not just a re-host of whatever ids a list endpoint happened to return.
///
/// Motivating bug: Plex's catalogue list/search responses can omit a title's
/// external `Guid` array, so a Plex **series** can arrive with *no strong id*.
/// Series match by strong external id only (never title — reboot/anime safety),
/// so such a series would key under **no** identity and silently fall out of the
/// store — making the cross-server set incomplete and breaking convergence with
/// Plex as the *destination* (the observed Plex→Jellyfin / Jellyfin→Plex
/// asymmetry).
///
/// The fix is to enrich **once, at population time**: for any movie/series that
/// resolves to no identity, fetch its fuller per-item record (e.g. Plex
/// `/library/metadata/{ratingKey}`, which *does* carry the `Guid` array) and
/// re-derive its identity before indexing. Enrichment only *fills in* ids — it
/// never loosens series matching to title — so it can't introduce a false-merge.
///
/// Failure handling (never a silent drop):
///  - fetch **failed** (network/asleep) ⇒ the item is left out *this* pass and
///    the account is reported **inconclusive** so a later warm retries it;
///  - fetch **succeeded but still no strong id** ⇒ conclusive: the title
///    genuinely has nothing to match on, so it's skipped without forcing endless
///    re-scans.
public enum IdentityEnrichment {
    public struct Result: Sendable, Equatable {
        /// Items ready to ingest (originals that already had ids + successfully
        /// enriched ones). Items still without an identity are omitted.
        public var indexable: [MediaItem]
        /// `true` when at least one enrichment fetch failed, so the caller should
        /// retry the account on a later warm rather than mark it conclusively built.
        public var inconclusive: Bool

        public init(indexable: [MediaItem], inconclusive: Bool) {
            self.indexable = indexable
            self.inconclusive = inconclusive
        }
    }

    /// Prepares a page of catalogue `items` for indexing, enriching any movie or
    /// series that resolves to no ``MediaIdentity``.
    ///
    /// - Parameters:
    ///   - items: a freshly fetched catalogue page (any kinds; only movies/series
    ///     are considered — others are dropped, mirroring the index's own rule).
    ///   - concurrency: how many enrichment fetches may be in flight at once. For
    ///     Plex a whole page can be guid-less, so enriching them one-by-one made the
    ///     per-page latency N sequential round-trips — a dominant cold-boot warm
    ///     cost. Bounded so it speeds up the scan without flooding the connection
    ///     pool or the small tvOS cooperative thread pool.
    ///   - fetchFull: fetches the fuller per-item record for an item that lacks a
    ///     strong id. Return `nil` to signal the fetch **failed** (inconclusive);
    ///     return the enriched item (ideally now carrying external ids) on success.
    public static func prepare(
        _ items: [MediaItem],
        concurrency: Int = 5,
        fetchFull: @Sendable @escaping (MediaItem) async -> MediaItem?
    ) async -> Result {
        // Partition without any network work: movies/series that already carry a
        // strong identity are ingestable as-is; the rest each need one enrichment
        // round-trip. Order is irrelevant downstream (the index keys by identity /
        // source id), so the enriched results can come back in any order.
        var indexable: [MediaItem] = []
        var needsFetch: [MediaItem] = []
        for item in items where item.kind == .movie || item.kind == .series {
            if MediaItemIdentity.identities(for: item).isEmpty {
                needsFetch.append(item)
            } else {
                indexable.append(item)
            }
        }
        guard !needsFetch.isEmpty else { return Result(indexable: indexable, inconclusive: false) }

        // Enrich the guid-less items concurrently, capped by a permit gate. Each
        // result carries (enrichedItem?, inconclusive): a nil fetch ⇒ inconclusive
        // (retry the account on a later warm); a fetch that returns but still lacks
        // a strong id ⇒ skipped conclusively (don't re-scan it forever).
        let limiter = ConcurrencyLimiter(limit: concurrency)
        let results: [(item: MediaItem?, inconclusive: Bool)] = await withTaskGroup(
            of: (MediaItem?, Bool).self
        ) { group in
            for item in needsFetch {
                group.addTask {
                    guard let full = await limiter.run({ await fetchFull(item) }) else {
                        return (nil, true)
                    }
                    if MediaItemIdentity.identities(for: full).isEmpty { return (nil, false) }
                    return (full, false)
                }
            }
            var collected: [(MediaItem?, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var inconclusive = false
        for result in results {
            if let item = result.item { indexable.append(item) }
            if result.inconclusive { inconclusive = true }
        }
        return Result(indexable: indexable, inconclusive: inconclusive)
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

/// The on-disk form of the ``IdentityIndex`` membership: a flat, JSON-friendly
/// value persisted as accounts warm and reloaded at launch so cross-server unions
/// are known at **t=0** (the cold-boot convergence fix). It carries only the
/// membership atoms and their freshness timestamps — never live watch-state, which
/// is always folded fresh from the loaded rows.
public struct PersistedIdentityIndex: Codable, Sendable, Equatable {
    /// One `(identity, source)` membership pair. Stored as a pair rather than an
    /// enum-keyed dictionary because `MediaIdentity` is an enum with associated
    /// values and so can't be a JSON object key.
    public struct Entry: Codable, Sendable, Equatable {
        public var identity: MediaIdentity
        public var source: IndexedSource

        public init(identity: MediaIdentity, source: IndexedSource) {
            self.identity = identity
            self.source = source
        }
    }

    /// account → its membership entries.
    public var entriesByAccount: [String: [Entry]]
    /// account → when its catalogue was last (re)built, so a reloaded account still
    /// re-warms on the normal staleness path.
    public var builtAtByAccount: [String: Date]

    public static let empty = PersistedIdentityIndex(entriesByAccount: [:], builtAtByAccount: [:])

    public init(entriesByAccount: [String: [Entry]], builtAtByAccount: [String: Date]) {
        self.entriesByAccount = entriesByAccount
        self.builtAtByAccount = builtAtByAccount
    }

    public var isEmpty: Bool { entriesByAccount.isEmpty }
}

/// Persistence seam for the identity index, mirroring the watch-outbox store: a
/// missing/corrupt file reads as ``PersistedIdentityIndex/empty`` so first launch
/// and torn writes recover cleanly.
public protocol IdentityIndexStoring: Sendable {
    func load() -> PersistedIdentityIndex
    func save(_ snapshot: PersistedIdentityIndex) throws
}

/// In-memory store for tests/previews and the safe default.
public final class InMemoryIdentityIndexStore: IdentityIndexStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PersistedIdentityIndex

    public init(_ snapshot: PersistedIdentityIndex = .empty) {
        self.snapshot = snapshot
    }

    public func load() -> PersistedIdentityIndex {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func save(_ snapshot: PersistedIdentityIndex) throws {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }
}

/// JSON-file-backed store. Atomic writes; profile-scoped by `namespace` so each
/// household profile keeps its own persisted membership.
public final class FileIdentityIndexStore: IdentityIndexStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(directory: URL? = nil, namespace: String? = nil) {
        let base = directory ?? Self.defaultDirectory()
        let suffix = namespace.map { "-\($0)" } ?? ""
        self.url = base.appendingPathComponent("identity-index\(suffix).json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Plozz", isDirectory: true)
    }

    public func load() -> PersistedIdentityIndex {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(PersistedIdentityIndex.self, from: data)) ?? .empty
    }

    public func save(_ snapshot: PersistedIdentityIndex) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
