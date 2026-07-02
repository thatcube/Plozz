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
    /// are active.
    private static let accountFanoutLimit = 3

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
    /// is stable-sorted by ``MediaItem/lastPlayedAt`` descending *after* the
    /// cross-server merge — so the unified most-recent-wins timestamp folded onto
    /// each card (progress made on *any* server) drives the order, and the row
    /// reflects what the user actually watched last instead of a round-robin
    /// interleave that shuffles between launches. Cards without a timestamp
    /// (e.g. Next Up entries that were never played, or a provider that doesn't
    /// report one) keep their interleave order *after* the timestamped ones.
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
            merged = sortedByRecency(merged)
        }
        guard merged.count > limit else { return merged }
        return Array(merged.prefix(limit))
    }

    /// Stable descending sort by ``MediaItem/lastPlayedAt``: timestamped cards
    /// newest-first, untimestamped cards after them in their original (interleave)
    /// order. Swift's `sort` isn't guaranteed stable, so ties are broken by the
    /// original offset to keep the order deterministic across launches.
    static func sortedByRecency(_ items: [MediaItem]) -> [MediaItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastPlayedAt, rhs.element.lastPlayedAt) {
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
