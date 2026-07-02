import Foundation
import CoreModels
import CoreNetworking

/// Fans out over every active account's provider and merges the results into the
/// unified Home/Settings content, tagging each item/library with its owning
/// account so callers can route a selection back to the right provider.
///
/// All fan-out is concurrent (`TaskGroup`/`async let`) and **resilient**: each
/// provider call is isolated, so one server being slow never blocks the others
/// and one server failing (or being down) simply contributes nothing rather than
/// failing the whole screen. It uses only the existing indexed/limited provider
/// queries — never a full-library walk.
public struct HomeAggregator: Sendable {
    public init() {}

    /// The merged Home content across all active accounts.
    public struct Content: Equatable, Sendable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        /// The unified Watchlist row, merged across every `WatchlistProviding`
        /// account (Jellyfin Favorites today). Empty when nothing is saved or no
        /// active account supports a watchlist — the UI then hides the row.
        public var watchlist: [MediaItem]
        /// Every discovered library (unfiltered); callers apply Home-visibility.
        public var libraries: [AggregatedLibrary]

        public init(
            continueWatching: [MediaItem] = [],
            latest: [MediaItem] = [],
            watchlist: [MediaItem] = [],
            libraries: [AggregatedLibrary] = []
        ) {
            self.continueWatching = continueWatching
            self.latest = latest
            self.watchlist = watchlist
            self.libraries = libraries
        }
    }

    /// Loads and merges Continue Watching, Recently Added, and Libraries across
    /// `accounts`. Per-account results keep their server order; Recently Added and
    /// Watchlist rows from different servers are round-robin interleaved so every
    /// server gets fair top-of-row representation, while Continue Watching is
    /// additionally sorted by ``MediaItem/lastPlayedAt`` (most-recent-wins across
    /// servers) so it reflects what was actually watched last.
    public func content(
        from accounts: [ResolvedAccount],
        continueWatchingLimit: Int = 20,
        latestLimit: Int = 20,
        watchlistLimit: Int = 20,
        visibility: HomeLibraryVisibility = .default,
        identitySources: @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) async -> Content {
        let clock = ContinuousClock()
        let started = clock.now
        let perAccount = await Self.loadPerAccount(accounts) { resolved in
            let accountStarted = clock.now
            let result = await Self.load(
                from: resolved,
                continueWatchingLimit: continueWatchingLimit,
                latestLimit: latestLimit,
                visibility: visibility
            )
            PlozzLog.boot("HomeAgg.account id=\(resolved.account.id) provider=\(resolved.account.server.provider) ms=\(Self.elapsedMS(from: accountStarted, to: clock.now)) cw=\(result.continueWatching.count) latest=\(result.latest.count) libs=\(result.libraries.count)")
            return result
        }
        PlozzLog.boot("HomeAgg.fanout accounts=\(accounts.count) ms=\(Self.elapsedMS(from: started, to: clock.now))")

        // Collapse the same title living on several servers into one card on the
        // aggregated rows, sharing the exact identity/merge core Search uses. Each
        // merged card keeps every server's own item id / versions / watch-state
        // (in `sources`) and surfaces a unified, most-recent-wins watch-state, so
        // progress made on any server shows here regardless of which one backs the
        // card.
        let serverInfo = accounts.sourceServerInfo()
        let resolve: (String) -> SourceServerInfo? = { serverInfo[$0] }

        return Content(
            continueWatching: Self.mergedRow(
                from: perAccount.map(\.continueWatching),
                limit: continueWatchingLimit,
                serverInfo: resolve,
                identitySources: identitySources,
                sortByRecency: true
            ),
            latest: Self.mergedRow(
                from: perAccount.map(\.latest),
                limit: latestLimit,
                serverInfo: resolve,
                identitySources: identitySources
            ),
            watchlist: Self.mergedRow(
                from: perAccount.map(\.watchlist),
                limit: watchlistLimit,
                serverInfo: resolve,
                identitySources: identitySources
            ),
            // Library TILES are NEVER merged across accounts/servers: every
            // enabled library keeps its own tile (keyed `accountID:library.id`)
            // showing exactly that server's content, so same-named libraries on
            // different servers/users don't fold into one and vanish. Cross-server
            // CONTENT merging is preserved on the rows above (`mergedRow`) and in
            // the detail server picker. Order is first account first, then each
            // account's own library order — matching the Settings checklist
            // (`libraries(from:)`).
            libraries: perAccount.flatMap(\.libraries)
        )
    }

    /// Discovers every library across `accounts`, tagged with account/provider
    /// metadata — used by the Settings checklist. Resilient per account.
    public func libraries(from accounts: [ResolvedAccount]) async -> [AggregatedLibrary] {
        let perAccount = await Self.loadPerAccount(accounts) { resolved in
            await Self.libraries(from: resolved)
        }
        return perAccount.flatMap { $0 }
    }

    // MARK: - Per-account loading

    private struct AccountContent: Sendable {
        var continueWatching: [MediaItem] = []
        var latest: [MediaItem] = []
        var watchlist: [MediaItem] = []
        var libraries: [AggregatedLibrary] = []
    }

    /// Bounded account-level fan-out for Home aggregation so launch-time network
    /// and decoding work can't swamp the UI and image pipeline when many accounts
    /// are active. Sized to a typical multi-server household so the last accounts
    /// don't wait behind the first few (a slow/asleep server in the first slots
    /// would otherwise ~double the time the remaining accounts take to surface).
    private static let accountFanoutLimit = 5

    /// Executes per-account work preserving account order while capping how many
    /// accounts run concurrently.
    private static func loadPerAccount<T: Sendable>(
        _ accounts: [ResolvedAccount],
        maxConcurrentAccounts: Int = accountFanoutLimit,
        operation: @escaping @Sendable (ResolvedAccount) async -> T
    ) async -> [T] {
        guard !accounts.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrentAccounts, accounts.count))
        return await withTaskGroup(of: (Int, T).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let resolved = accounts[index]
                group.addTask { (index, await operation(resolved)) }
            }

            var byIndex: [Int: T] = [:]
            while let (index, value) = await group.next() {
                byIndex[index] = value
                if nextIndex < accounts.count {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let resolved = accounts[queuedIndex]
                    group.addTask { (queuedIndex, await operation(resolved)) }
                }
            }
            return accounts.indices.compactMap { byIndex[$0] }
        }
    }

    private static func load(
        from resolved: ResolvedAccount,
        continueWatchingLimit: Int,
        latestLimit: Int,
        visibility: HomeLibraryVisibility
    ) async -> AccountContent {
        let accountID = resolved.account.id
        let provider = resolved.provider

        // Only accounts with at least one hidden library pay for the
        // library-scoped fetch path. When nothing is hidden we keep the original
        // single-shot, fully-concurrent fetch — zero behaviour/performance change.
        let accountHasHidden = visibility.excludedKeys.contains { $0.hasPrefix("\(accountID):") }

        // Libraries and watchlist load independently of the row strategy.
        async let libs = try? provider.libraries()
        async let saved = Self.watchlist(from: provider)

        let cw: [MediaItem]
        let lt: [MediaItem]
        let rawLibs: [MediaLibrary]

        if accountHasHidden {
            // Resolve the library list first so the row fetches can be scoped to
            // the *visible* libraries. For providers that can only learn an item's
            // owning library by scoping the fetch (Jellyfin — an episode's
            // ParentId is its season, not its library), this both excludes hidden
            // content at the source and stamps each item's `libraryID`. Providers
            // that tag items by other means (Plex) inherit the unscoped default
            // and rely on the row-level filter.
            rawLibs = (await libs) ?? []
            let visibleLibraryIDs = rawLibs
                .map(\.id)
                .filter { visibility.isVisible("\(accountID):\($0)") }
            async let resume = try? provider.continueWatching(limit: continueWatchingLimit, inLibraries: visibleLibraryIDs)
            async let recent = try? provider.latest(limit: latestLimit, inLibraries: visibleLibraryIDs)
            cw = (await resume) ?? []
            lt = (await recent) ?? []
        } else {
            async let resume = try? provider.continueWatching(limit: continueWatchingLimit)
            async let recent = try? provider.latest(limit: latestLimit)
            cw = (await resume) ?? []
            lt = (await recent) ?? []
            rawLibs = (await libs) ?? []
        }

        let wl = await saved

        if cw.isEmpty && lt.isEmpty && rawLibs.isEmpty {
            PlozzLog.app.error("Aggregation: no content from account \(accountID)")
        }

        return AccountContent(
            continueWatching: cw.map { $0.taggingSource(accountID) },
            latest: lt.map { $0.taggingSource(accountID) },
            watchlist: wl.map { $0.taggingSource(accountID) },
            libraries: rawLibs.map { aggregated($0, from: resolved) }
        )
    }

    /// Best-effort watchlist fetch for one provider: `[]` when the provider can't
    /// express a watchlist or the request fails, so the row degrades gracefully.
    private static func watchlist(from provider: any MediaProvider) async -> [MediaItem] {
        guard let watchlistProvider = provider as? WatchlistProviding else { return [] }
        return (try? await watchlistProvider.watchlist()) ?? []
    }

    private static func libraries(from resolved: ResolvedAccount) async -> [AggregatedLibrary] {
        do {
            let libs = try await resolved.provider.libraries()
            return libs.map { aggregated($0, from: resolved) }
        } catch {
            PlozzLog.app.error("Aggregation: failed to list libraries for account \(resolved.account.id)")
            return []
        }
    }

    private static func aggregated(_ library: MediaLibrary, from resolved: ResolvedAccount) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: resolved.account.id,
            accountName: resolved.account.userName,
            serverName: resolved.account.server.name,
            providerKind: resolved.account.server.provider,
            library: library.taggingSource(resolved.account.id)
        )
    }

    /// Interleaves and de-duplicates one Home row, then caps the rendered count so
    /// Home remains responsive with many accounts.
    ///
    /// When `sortByRecency` is set (the Continue Watching row) the merged result
    /// is stable-sorted by an effective recency (see ``sortedByRecency(_:effectiveByRef:)``)
    /// so the row reflects what the user actually watched last instead of a
    /// round-robin interleave that shuffles between launches. The recency that
    /// anchors untimestamped "Next Up" cards is computed **per feed, before the
    /// interleave** (``effectiveRecency(forFeeds:)``) so a suggestion travels with
    /// its *own* server's recency and can never inherit a foreign server's
    /// timestamp. Cards with no effective recency keep their interleave order
    /// *after* the timestamped ones.
    private static func mergedRow(
        from groups: [[MediaItem]],
        limit: Int,
        serverInfo: (String) -> SourceServerInfo?,
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] },
        sortByRecency: Bool = false
    ) -> [MediaItem] {
        guard limit > 0 else { return [] }
        var merged = MediaItemMerger.merge(
            Self.interleave(groups),
            serverInfo: serverInfo,
            identitySources: identitySources
        )
        if sortByRecency {
            merged = sortedByRecency(merged, effectiveByRef: effectiveRecency(forFeeds: groups))
        }
        guard merged.count > limit else { return merged }
        return Array(merged.prefix(limit))
    }

    /// Stable descending sort of a merged Continue Watching row by an **effective
    /// recency** supplied per source ref.
    ///
    /// Continue Watching feeds arrive newest-first, and each "Next Up" suggestion
    /// sits right below the in-progress episode whose series spawned it — but those
    /// suggestions carry no play timestamp of their own (`lastPlayedAt == nil`). The
    /// recency that anchors them is computed **per feed, before the cross-server
    /// interleave** (see ``effectiveRecency(forFeeds:)``) and passed in here as
    /// `effectiveByRef`, keyed by ``MediaSourceRef/id`` ("account:item").
    ///
    /// Doing the carry-forward per feed — instead of over the *interleaved*
    /// sequence — is the fix for the reported bug: an earlier version walked the
    /// already-interleaved row, so a nil card inherited whatever **foreign** server's
    /// card happened to interleave above it. That let the next episode of a show you
    /// last touched weeks ago steal a *different* server's fresh timestamp and jump
    /// the queue (and, because the interleave is account-order dependent, the result
    /// shifted between launches) — exactly the "Continue Watching is different from
    /// what I watched last / keeps shifting around" symptom.
    ///
    /// Each merged card's effective recency is the max over (its own `lastPlayedAt`
    /// and the `effectiveByRef` entry of every source it merged) so a card backed by
    /// several servers ranks by its most recent activity *anywhere*. Cards with no
    /// effective recency keep their incoming order after the timestamped ones.
    ///
    /// The sort is stable (equal effective recency breaks by the original offset)
    /// **and idempotent**. When `effectiveByRef` is empty it degrades to a plain
    /// stable "timestamped first by `lastPlayedAt`, everything else in place" sort
    /// with **no** carry-forward — for callers that operate on an already-ordered
    /// row and must never re-derive order from a (now absent) interleave.
    static func sortedByRecency(
        _ items: [MediaItem],
        effectiveByRef: [String: Date] = [:]
    ) -> [MediaItem] {
        let keyed = items.enumerated().map { offset, element -> (offset: Int, element: MediaItem, effective: Date?) in
            var effective = element.lastPlayedAt
            if !effectiveByRef.isEmpty {
                for ref in element.sources {
                    guard let candidate = effectiveByRef[ref.id] else { continue }
                    if effective == nil || candidate > effective! { effective = candidate }
                }
            }
            return (offset, element, effective)
        }
        return keyed.sorted { lhs, rhs in
            switch (lhs.effective, rhs.effective) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Per-feed effective recency for Continue Watching, keyed by
    /// ``MediaSourceRef/id`` ("account:item").
    ///
    /// Each server's Continue Watching feed arrives newest-first with its "Next Up"
    /// suggestions (`lastPlayedAt == nil`) sitting just below the in-progress
    /// episode that spawned them. Walking **each feed independently** top-to-bottom
    /// and carrying the last seen timestamp forward gives every untimestamped card
    /// the recency of its own series — and, critically, never lets a card inherit a
    /// *different* server's timestamp (which the old post-interleave carry-forward
    /// did). Leading untimestamped cards (nothing timestamped above them in their
    /// own feed) get no entry and sort after the timestamped cards.
    ///
    /// Keyed by (account, item) so the map survives the cross-server merge: a merged
    /// card looks up each of its `sources` and takes the max, so progress on any one
    /// server floats the unified card.
    static func effectiveRecency(forFeeds feeds: [[MediaItem]]) -> [String: Date] {
        var result: [String: Date] = [:]
        for feed in feeds {
            var carry: Date?
            for item in feed {
                guard let account = item.sourceAccountID else { continue }
                let key = "\(account):\(item.id)"
                if let timestamp = item.lastPlayedAt {
                    carry = timestamp
                    result[key] = timestamp
                } else if let carry {
                    result[key] = carry
                }
            }
        }
        return result
    }

    // MARK: - Merge

    /// Round-robin interleave: take the first item of every group, then the
    /// second of every group, and so on. Preserves each group's internal order
    /// and gives every account fair top-of-row placement.
    static func interleave<T>(_ groups: [[T]]) -> [T] {
        let maxCount = groups.map(\.count).max() ?? 0
        var result: [T] = []
        result.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for offset in 0..<maxCount {
            for group in groups where offset < group.count {
                result.append(group[offset])
            }
        }
        return result
    }

    /// Whole milliseconds between two `ContinuousClock` instants, for PLZBOOT
    /// timing. Env-gated logging only — never on a user-visible path.
    private static func elapsedMS(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let comps = (end - start).components
        // 1 ms = 1e15 attoseconds.
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }
}
