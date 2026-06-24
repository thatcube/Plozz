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

        // Collapse the same title living on several servers into one card on the
        // aggregated rows, sharing the exact identity/merge core Search uses. Each
        // merged card keeps every server's own item id / versions / watch-state
        // (in `sources`) and surfaces a unified, most-recent-wins watch-state, so
        // progress made on any server shows here regardless of which one backs the
        // card. Per-library browse stays single-source (see the brief's carve-out).
        let serverInfo = accounts.sourceServerInfo()
        let resolve: (String) -> SourceServerInfo? = { serverInfo[$0] }

        return Content(
            continueWatching: MediaItemMerger.merge(
                Self.interleave(perAccount.map(\.continueWatching)), serverInfo: resolve),
            latest: MediaItemMerger.merge(
                Self.interleave(perAccount.map(\.latest)), serverInfo: resolve),
            watchlist: MediaItemMerger.merge(
                Self.interleave(perAccount.map(\.watchlist)), serverInfo: resolve),
            libraries: Self.mergeLibraries(perAccount.flatMap(\.libraries))
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

    /// Collapses the *same* library living on several servers (e.g. a "Movies"
    /// library on both a Plex and a Jellyfin account) into ONE tile on the Home
    /// Libraries row, so its content can be browsed cross-server and a title
    /// appears once (criterion 1, Library-browse half). The **first-seen**
    /// `AggregatedLibrary` stays primary — preserving its stable Home-visibility
    /// `key` — with every other server folded into its underlying
    /// `MediaLibrary.additionalSourceAccountIDs` / `sourceContainerIDByAccount`,
    /// so tapping the tile opens an aggregated cross-server browse.
    ///
    /// Grouped by normalized title + kind (libraries carry no external ids).
    /// Untitled libraries fall back to their unique key so they never collapse by
    /// an empty name. The Settings checklist keeps the **un-merged** per-account
    /// list via `libraries(from:)`, so each server's library stays individually
    /// toggleable.
    static func mergeLibraries(_ libraries: [AggregatedLibrary]) -> [AggregatedLibrary] {
        var order: [String] = []
        var primaryByKey: [String: AggregatedLibrary] = [:]

        for aggregated in libraries {
            let normalized = MediaItemIdentity.normalizedTitle(aggregated.library.title)
            let key = normalized.isEmpty
                ? "id:\(aggregated.key)"
                : "\(aggregated.library.kind.rawValue):\(normalized)"

            guard var primary = primaryByKey[key] else {
                primaryByKey[key] = aggregated
                order.append(key)
                continue
            }

            let accountID = aggregated.accountID
            if accountID != primary.library.sourceAccountID,
               !primary.library.additionalSourceAccountIDs.contains(accountID) {
                primary.library.additionalSourceAccountIDs.append(accountID)
            }
            for (account, container) in aggregated.library.sourceContainerIDByAccount
            where primary.library.sourceContainerIDByAccount[account] == nil {
                primary.library.sourceContainerIDByAccount[account] = container
            }
            primaryByKey[key] = primary
        }

        return order.compactMap { primaryByKey[$0] }
    }

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
