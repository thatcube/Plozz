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
    /// `accounts`. Per-account results keep their server order; rows from
    /// different servers are round-robin interleaved so every server gets fair
    /// top-of-row representation (`MediaItem` carries no timestamp to sort by).
    public func content(
        from accounts: [ResolvedAccount],
        continueWatchingLimit: Int = 20,
        latestLimit: Int = 20,
        watchlistLimit: Int = 20
    ) async -> Content {
        let perAccount = await Self.loadPerAccount(accounts) { resolved in
            await Self.load(
                from: resolved,
                continueWatchingLimit: continueWatchingLimit,
                latestLimit: latestLimit
            )
        }

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
                serverInfo: resolve
            ),
            latest: Self.mergedRow(
                from: perAccount.map(\.latest),
                limit: latestLimit,
                serverInfo: resolve
            ),
            watchlist: Self.mergedRow(
                from: perAccount.map(\.watchlist),
                limit: watchlistLimit,
                serverInfo: resolve
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
        latestLimit: Int
    ) async -> AccountContent {
        let accountID = resolved.account.id
        let provider = resolved.provider

        // Each call is independent so a single failing endpoint still yields the
        // account's other rows.
        async let resume = try? provider.continueWatching(limit: continueWatchingLimit)
        async let recent = try? provider.latest(limit: latestLimit)
        async let libs = try? provider.libraries()
        // Only providers that advertise a watchlist contribute to that row.
        async let saved = Self.watchlist(from: provider)

        let cw = (await resume) ?? []
        let lt = (await recent) ?? []
        let rawLibs = (await libs) ?? []
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
    private static func mergedRow(
        from groups: [[MediaItem]],
        limit: Int,
        serverInfo: (String) -> SourceServerInfo?
    ) -> [MediaItem] {
        guard limit > 0 else { return [] }
        let merged = MediaItemMerger.merge(Self.interleave(groups), serverInfo: serverInfo)
        guard merged.count > limit else { return merged }
        return Array(merged.prefix(limit))
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
}
