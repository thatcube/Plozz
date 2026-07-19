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
    /// The source's ``MediaItemIdentity/normalizedTitle(_:)`` title, retained so the
    /// membership walk can split a bad shared external id apart (one server tagging
    /// two different movies with the same TMDb/IMDb id). `nil` for entries indexed
    /// before this field existed / titleless items — treated as "no title signal"
    /// so a sparse twin is never split (only a positive title+year contradiction
    /// ejects). Stored normalized so the split-guard needn't re-fold on every walk.
    public var normalizedTitle: String?
    /// The source's production year, paired with ``normalizedTitle`` for the
    /// split-guard's year-corroboration check. `nil` = no year signal.
    public var year: Int?

    public init(
        accountID: String,
        itemID: String,
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        locality: SourceLocality? = nil,
        kind: MediaItemKind = .unknown,
        normalizedTitle: String? = nil,
        year: Int? = nil
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.locality = locality
        self.kind = kind
        self.normalizedTitle = normalizedTitle
        self.year = year
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
            kind: kind,
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
    /// Reverse map: a source's `id` ("accountID:itemID") → every identity it was
    /// indexed under. Lets a **loaded row whose payload carried no strong external
    /// id** (Plex list responses can omit the `Guid` array) recover the index's
    /// enriched identities for that exact physical item, so it still resolves its
    /// full cross-server set and merges with a twin that *does* carry an id.
    private let bySource: [String: [MediaIdentity]]

    public init(byIdentity: [MediaIdentity: [IndexedSource]]) {
        let sorted = byIdentity.mapValues { sources in
            sources.sorted { $0.id < $1.id }
        }
        self.byIdentity = sorted
        var reverse: [String: [MediaIdentity]] = [:]
        for (identity, sources) in sorted {
            for source in sources {
                reverse[source.id, default: []].append(identity)
            }
        }
        // Dictionary iteration order is nondeterministic across launches (Swift
        // seeds its hashing per process), so the identity lists appended above
        // arrive in an arbitrary order. Sort each list by a stable key so a
        // recovered-identity lookup — and therefore the unioned source order the
        // cross-server selector tie-breaks on — is identical across rebuilds.
        // Without this the "best source" for a title could flip between launches
        // (the reported "it's almost random which server I end up on" symptom).
        self.bySource = reverse.mapValues { identities in
            identities.sorted { Self.stableSortKey($0) < Self.stableSortKey($1) }
        }
    }

    /// A deterministic, launch-stable ordering key for a ``MediaIdentity`` (the enum
    /// is `Hashable` but not `Comparable`). The leading digit groups by case so the
    /// order is total and cannot collide across cases.
    private static func stableSortKey(_ identity: MediaIdentity) -> String {
        switch identity {
        case let .external(source, value):
            return "0:\(source):\(value)"
        case let .title(normalizedTitle, year, kind):
            return "1:\(normalizedTitle):\(year.map(String.init) ?? "?"):\(kind.rawValue)"
        case let .sameItemID(id):
            return "2:\(id)"
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
    ///
    /// This is a **single-level** union (the sources indexed directly under the
    /// given identities). For the transitive connected-component union — needed
    /// when a title's metadata is spread unevenly across servers — use
    /// ``sources(forIdentities:kind:)`` or ``sources(for:)``, which walk the shared
    /// id graph. This kind-less single-level form is kept for the legacy /
    /// kind-unknown path where a transitive walk could bridge across kinds.
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

    /// The transitive, **kind-scoped** connected-component union for a set of seed
    /// identities. External ids form a graph: two items are the same title if a
    /// chain of shared ids links them, even when no single id is shared by all
    /// (A=IMDb+TMDb, B=IMDb-only, C=TMDb-only — B and C are the same title bridged
    /// by A, though they share no id directly). A single-level union from the
    /// *sparse* node B would miss C; ``MediaItemMerger`` recovers this via union-find,
    /// but the direct snapshot lookups did not, so a card resolved from B's
    /// perspective was missing C's server (r8-transitive-component). Walking the
    /// closure here makes the index agree with the merger.
    ///
    /// Kind is enforced **during** the walk, not merely at the end: TMDb/TVDb reuse
    /// one integer id space across movies and series (movie 550 ≠ tv 550), so an
    /// unscoped closure could bridge two unrelated movies *through* a same-id series
    /// (M1—tmdb:550—S1—tvdb:100—M2) and a trailing kind filter would still hand back
    /// {M1, M2} as one movie. Only traversing and collecting same-kind sources keeps
    /// the component confined to the title's own kind.
    public func sources(forIdentities identities: [MediaIdentity], kind: MediaItemKind?) -> [IndexedSource] {
        sources(forIdentities: identities, kind: kind, anchorTitle: nil, anchorYear: nil)
    }

    /// As ``sources(forIdentities:kind:)``, but with an optional **anchor** title/year
    /// that splits a bad shared external id apart during the walk. Any same-kind
    /// source whose stored title/year ``MediaItemIdentity/titlesPlausiblyContradict``
    /// the anchor is dropped **and not traversed through** — so two different works
    /// bridged by one server's mis-tagged TMDb/IMDb/TVDb id don't contaminate the
    /// anchor title's version picker, best-source playback, or watch fan-out. This
    /// covers both a mis-tagged **movie** pair (Scream 6 tagged with Scream 7's id,
    /// split on title/year) and a mis-tagged **series** pair (a server emitting one
    /// TVDb id for both the 1999 anime and 2023 live-action "One Piece", split on the
    /// large production-year gap). `nil`/kind-unknown anchor = the prior unguarded
    /// union, so legacy callers behave exactly as before. Absent title/year signals
    /// on a source never contradict, so a sparse twin is never split.
    public func sources(
        forIdentities identities: [MediaIdentity],
        kind: MediaItemKind?,
        anchorTitle: String?,
        anchorYear: Int?
    ) -> [IndexedSource] {
        guard let kind else {
            // Kind-unknown (e.g. a legacy mutation predating the kind field): fall
            // back to a single-level union so a transitive walk can't fold unrelated
            // kinds together on a shared external id.
            return sources(forIdentities: identities)
        }
        guard !identities.isEmpty else { return [] }
        // The split-guard can only positively contradict a same-kind movie (needs a
        // usable title) or series (needs a year to measure the large-gap remake /
        // anime-vs-live-action signal); anything else leaves it inert (the union is
        // returned whole, as before). The primitive itself is the final arbiter —
        // this just skips the call when there's provably no anchor signal.
        let guardActive: Bool = {
            switch kind {
            case .movie: return !(anchorTitle ?? "").isEmpty
            case .series: return anchorYear != nil
            default: return false
            }
        }()
        var visitedIdentities = Set<MediaIdentity>()
        var frontier = identities
        var seenSources = Set<String>()
        var result: [IndexedSource] = []
        while let identity = frontier.popLast() {
            guard visitedIdentities.insert(identity).inserted else { continue }
            guard let sources = byIdentity[identity] else { continue }
            for source in sources where source.kind == kind {
                // A source that plausibly contradicts the anchor is a different work
                // riding a bad shared id: exclude it from the result AND from the
                // frontier, so nothing reachable only *through* it leaks in either.
                if guardActive,
                   MediaItemIdentity.titlesPlausiblyContradict(
                       titleA: anchorTitle ?? "",
                       yearA: anchorYear,
                       kindA: kind,
                       titleB: source.normalizedTitle ?? "",
                       yearB: source.year,
                       kindB: source.kind
                   ) {
                    continue
                }
                if seenSources.insert(source.id).inserted {
                    result.append(source)
                }
                // Expand through this same-kind source's other identities so a
                // sparse twin (that shares only *one* of the seed's ids) still pulls
                // in the rest of the component.
                if let more = bySource[source.id] {
                    for next in more where !visitedIdentities.contains(next) {
                        frontier.append(next)
                    }
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Every indexed source for `item`, by its ``MediaItemIdentity`` identities,
    /// **scoped to the item's kind** and unioned across the full transitive
    /// connected component (see ``sources(forIdentities:kind:)``). TMDb/TVDb reuse
    /// the same integer id across movies and series (movie 550 ≠ tv 550), and
    /// `identities(for:)` emits bare, kind-less external ids — so a kind-scoped walk
    /// keeps enrichment correct; episode expansion asks for series membership
    /// through the series probe, not here.
    ///
    /// The item's own title/year anchor the walk's split-guard, so a bad shared
    /// external id can't fold a *different* work (a mis-tagged movie, or the anime
    /// vs live-action of a same-named series) into this title's picker / play /
    /// watch-fan-out set (see ``sources(forIdentities:kind:anchorTitle:anchorYear:)``).
    public func sources(for item: MediaItem) -> [IndexedSource] {
        let kind = item.kind
        var identities = MediaItemIdentity.identities(for: item)
        // Recover the index's enriched identities for this *exact* physical item
        // when its loaded payload carried no strong external id (or fewer ids than
        // the index found by per-item fetch during warm). Without this an id-less
        // Plex row can't share an identity key with a Jellyfin twin that carries an
        // IMDb/TMDb id — rule #1 suppresses the twin's title key — so they'd stay
        // two cards even though the index knows they're one title. Keyed by the
        // row's own (account,item), so it's the index's confident per-item truth,
        // never a guess: no false-merge risk.
        if let accountID = item.sourceAccountID,
           let recovered = bySource["\(accountID):\(item.id)"] {
            identities.append(contentsOf: recovered)
        }
        // Re-apply rule #1 (see `MediaItemIdentity.identities(for:)`): a strong
        // external id has a well-defined catalogue identity and *suppresses* the
        // title/year fallback. `identities(for:)` guarantees this for the row's own
        // payload, but the recovery above can re-introduce a `.title` alongside a
        // recovered `.external` for an id-less row. Seeding the walk with both would
        // let the title key bridge this title to a *different* same-title/same-year
        // film that is id-less in the index — a false merge (the worst failure mode:
        // it also mis-targets the watch fan-out at an unrelated title). Drop the
        // title fallback whenever any strong external id is present so this lookup
        // upholds the same invariant as `identities(for:)`.
        if identities.contains(where: { if case .external = $0 { return true } else { return false } }) {
            identities.removeAll { if case .title = $0 { return true } else { return false } }
        }
        let normalized = MediaItemIdentity.normalizedTitle(item.title)
        return sources(
            forIdentities: identities,
            kind: kind,
            anchorTitle: normalized.isEmpty ? nil : normalized,
            anchorYear: item.productionYear
        )
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
    /// Shadow buckets for accounts with an in-flight rebuild. A rebuild ingests
    /// into its shadow bucket (never the live one), then ``finishRebuild(for:)``
    /// atomically swaps it into `byAccount`. This keeps the account's *existing*
    /// sources serving fan-out for the entire rebuild window (so a watch never
    /// misses a union just because a re-scan is mid-flight), and means a rebuild
    /// that never conclusively finishes — an inconclusive scan — leaves the live
    /// bucket and the persisted membership untouched rather than clobbering them.
    private var pendingRebuild: [String: [MediaIdentity: [String: IndexedSource]]] = [:]
    /// Accounts with an in-flight rebuild — routes ``ingest`` to the shadow bucket.
    private var rebuilding: Set<String> = []
    /// Accounts whose initial catalogue scan has completed at least once.
    private var warmAccounts: Set<String> = []
    /// When each account's catalogue was last (re)built, for staleness checks.
    private var builtAtByAccount: [String: Date] = [:]
    /// Memoized fold of `byAccount` into one identity → sources snapshot. Cleared
    /// by every content mutation that changes the **live** index (`ingest` into a
    /// non-rebuilding account, `finishRebuild`'s shadow swap, `removeAccount`,
    /// `restore`) so a stale merge is never served, and repopulated lazily on the
    /// next ``snapshot()``. A rebuild in flight does NOT clear it — the live view is
    /// unchanged until the atomic swap. Lets repeated reads with no intervening live
    /// mutation — the post-warm steady state, diagnostics, and the skip-warm restore
    /// path — reuse the built value instead of re-deriving the full map each time.
    private var cachedSnapshot: IdentityIndexSnapshot?
    private let now: @Sendable () -> Date

    public init(now: @Sendable @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Folds every account's bucket into one identity → sources map. Cheap enough
    /// to call after each account finishes warming so readers see progress early;
    /// memoized so a call with no intervening mutation reuses the built value.
    public func snapshot() -> IdentityIndexSnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        var merged: [MediaIdentity: [IndexedSource]] = [:]
        for (_, identityMap) in byAccount {
            for (identity, sourcesByID) in identityMap {
                merged[identity, default: []].append(contentsOf: sourcesByID.values)
            }
        }
        let built = IdentityIndexSnapshot(byIdentity: merged)
        cachedSnapshot = built
        return built
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
        // While an account is rebuilding, ingest into its shadow bucket so the live
        // sources keep serving fan-out untouched until the swap at finishRebuild.
        let intoShadow = rebuilding.contains(accountID)
        var bucket = (intoShadow ? pendingRebuild[accountID] : byAccount[accountID]) ?? [:]
        for item in items {
            guard item.kind == .movie || item.kind == .series else { continue }
            let identities = MediaItemIdentity.identities(for: item)
            guard !identities.isEmpty else { continue }
            let normalized = MediaItemIdentity.normalizedTitle(item.title)
            let source = IndexedSource(
                accountID: accountID,
                itemID: item.id,
                providerKind: serverInfo?.providerKind,
                serverName: serverInfo?.serverName,
                accountName: serverInfo?.accountName,
                locality: serverInfo?.locality,
                kind: item.kind,
                normalizedTitle: normalized.isEmpty ? nil : normalized,
                year: item.productionYear
            )
            for identity in identities {
                bucket[identity, default: [:]][source.id] = source
            }
        }
        if intoShadow {
            // The live snapshot is unchanged during a rebuild — don't invalidate it.
            pendingRebuild[accountID] = bucket
        } else {
            byAccount[accountID] = bucket
            cachedSnapshot = nil
        }
    }

    /// Opens a shadow bucket for `accountID`'s re-scan. The account's **existing**
    /// live sources keep serving fan-out (and stay warm, and stay exportable as
    /// last-known-good) throughout the rebuild; ``ingest`` routes the new page into
    /// the shadow, and ``finishRebuild(for:)`` atomically swaps it in. A rebuild
    /// that never finishes therefore leaves the live index untouched — no stale-out
    /// window, no persisted-membership clobber.
    public func beginRebuild(for accountID: String) {
        pendingRebuild[accountID] = [:]
        rebuilding.insert(accountID)
    }

    /// Marks `accountID`'s scan complete: atomically swaps the shadow bucket into
    /// the live index (if a rebuild was in flight) and records its freshness
    /// timestamp.
    public func finishRebuild(for accountID: String) {
        if rebuilding.contains(accountID) {
            byAccount[accountID] = pendingRebuild[accountID] ?? [:]
            pendingRebuild[accountID] = nil
            rebuilding.remove(accountID)
            cachedSnapshot = nil
        }
        warmAccounts.insert(accountID)
        builtAtByAccount[accountID] = now()
    }

    /// Drops an account entirely (sign-out / profile switch), so its sources stop
    /// appearing in the snapshot immediately.
    public func removeAccount(_ accountID: String) {
        byAccount[accountID] = nil
        pendingRebuild[accountID] = nil
        rebuilding.remove(accountID)
        warmAccounts.remove(accountID)
        builtAtByAccount[accountID] = nil
        cachedSnapshot = nil
    }

    /// Prunes any indexed account not in `accountIDs` (e.g. after a profile switch
    /// narrows the active set), keeping the snapshot honest. Also prunes accounts
    /// that exist only as an in-flight rebuild (a brand-new account whose first scan
    /// hasn't finished), so a removed server mid-scan leaves no shadow behind.
    ///
    /// Resurrection invariant (why a superseded warm wave can't undo this prune):
    /// the actor serializes all of `ingest`/`beginRebuild`/`retainAccounts`, and the
    /// caller (`AppState.warmIdentityIndex`) always calls `identityWarmTask.cancel()`
    /// **before** it awaits the next wave's `retainAccounts`. So by the time this
    /// runs, every already-issued `ingest` from the prior wave has either completed
    /// (queued on the actor ahead of us) or been abandoned by the `Task.isCancelled`
    /// checks guarding each `ingest`/`beginRebuild`. A pruned account therefore has
    /// no later write racing behind this call to resurrect its bucket — a new wave
    /// only re-adds an account by re-selecting it into `accountsToWarm`, which
    /// happens after this prune, not concurrently with it.
    public func retainAccounts(_ accountIDs: Set<String>) {
        let known = Set(byAccount.keys).union(pendingRebuild.keys)
        for accountID in known where !accountIDs.contains(accountID) {
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
                // Uphold the same invariant as `ingest`: only movies and series carry
                // a stable cross-server identity. An older build (or a corrupt
                // snapshot) may have persisted an episode/other-kind source; restoring
                // it would let a kind-scoped lookup serve a wrong same-kind membership
                // (and is how a stale cross-kind twin could re-enter). Reject it here.
                guard entry.source.kind == .movie || entry.source.kind == .series else { continue }
                bucket[entry.identity, default: [:]][entry.source.id] = entry.source
            }
            guard !bucket.isEmpty else { continue }
            byAccount[accountID] = bucket
            warmAccounts.insert(accountID)
            builtAtByAccount[accountID] = persisted.builtAtByAccount[accountID] ?? .distantPast
            restoredAny = true
        }
        if restoredAny { cachedSnapshot = nil }
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

    /// A `@Sendable` identity-sources lookup over the **live** snapshot, suitable
    /// for the ``MediaItemMerger`` enrichment seam and the watch fan-out.
    ///
    /// The closure reads ``current`` on every call by design — it must stay LIVE:
    /// surface closures (Search / the tab view) are captured once for the view's
    /// lifetime and have to reflect the index growing as accounts warm, otherwise a
    /// card would keep a stale cross-server set and play-time selection would miss a
    /// same-LAN twin discovered later (the very bug the index exists to fix). This
    /// is cheap: `IdentityIndexSnapshot` is a value type backing onto copy-on-write
    /// dictionaries, so `current` is an uncontended `NSLock` acquire plus a couple
    /// of retains — sub-microsecond per item, dwarfed by the identity extraction and
    /// dictionary lookups in `sourceRefs(for:)`. A frozen snapshot would shave that
    /// micro-cost off large browse merges but at the cost of live-ness, which is not
    /// a trade worth making.
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
        // v5 uses authoritative Series* IDs plus exact S/E for cross-provider
        // episode membership. Do not restore an older snapshot that used title
        // heuristics or may have collapsed show-level IDs;
        // this is a purgeable cache and is rebuilt from active providers. Only
        // movie/series sources are ever exported (see `export`), and `restore`
        // additionally rejects any non-movie/series entry, so a corrupt snapshot
        // can't reintroduce a cross-kind membership — no schema bump needed.
        self.url = base.appendingPathComponent("identity-index-v5\(suffix).json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        // tvOS does not persist `Application Support` (the directory doesn't survive
        // a relaunch on device), so a persisted identity index written there was
        // silently lost on every restart — the cross-server membership had to be
        // rebuilt from scratch each launch. `Library/Caches` persists across normal
        // tvOS launches (matching every other durable store in the app).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Plozz", isDirectory: true)
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
