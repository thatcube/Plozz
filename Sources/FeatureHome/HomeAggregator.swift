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
        latestLimit: Int = 20
    ) async -> Content {
        let perAccount = await withTaskGroup(of: (Int, AccountContent).self) { group in
            for (index, resolved) in accounts.enumerated() {
                group.addTask {
                    (index, await Self.load(
                        from: resolved,
                        continueWatchingLimit: continueWatchingLimit,
                        latestLimit: latestLimit
                    ))
                }
            }
            var byIndex: [Int: AccountContent] = [:]
            for await (index, content) in group { byIndex[index] = content }
            return accounts.indices.map { byIndex[$0] ?? AccountContent() }
        }

        return Content(
            continueWatching: Self.interleave(perAccount.map(\.continueWatching)),
            latest: Self.interleave(perAccount.map(\.latest)),
            watchlist: Self.interleave(perAccount.map(\.watchlist)),
            libraries: perAccount.flatMap(\.libraries)
        )
    }

    /// Discovers every library across `accounts`, tagged with account/provider
    /// metadata — used by the Settings checklist. Resilient per account.
    public func libraries(from accounts: [ResolvedAccount]) async -> [AggregatedLibrary] {
        let perAccount = await withTaskGroup(of: (Int, [AggregatedLibrary]).self) { group in
            for (index, resolved) in accounts.enumerated() {
                group.addTask {
                    (index, await Self.libraries(from: resolved))
                }
            }
            var byIndex: [Int: [AggregatedLibrary]] = [:]
            for await (index, libs) in group { byIndex[index] = libs }
            return accounts.indices.map { byIndex[$0] ?? [] }
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
