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
        forceLibraryScoping: Bool = false,
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
                visibility: visibility,
                forceLibraryScoping: forceLibraryScoping
            )
            PlozzLog.boot("HomeAgg.account id=\(resolved.account.id) provider=\(resolved.account.server.provider) ms=\(Self.elapsedMS(from: accountStarted, to: clock.now)) cw=\(result.continueWatching.count) latest=\(result.latest.count) wl=\(result.watchlist.count) libs=\(result.libraries.count)")
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
            //
            // **Music libraries are excluded from Home entirely** — they have their
            // own dedicated Music tab, so they never appear as a Home tile (merged)
            // or a per-library section (unmerged). They remain in `libraries(from:)`
            // for the Settings list so the user can still enable/disable them.
            libraries: perAccount.flatMap(\.libraries).filter { !$0.library.isMusic }
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

    // MARK: - Unmerged (per-library) content

    /// The Home content when the profile has turned **off** "Merge libraries on
    /// Home": the global Continue Watching + Watchlist rows stay cross-server merged
    /// at the top (built by the merged ``content(from:)`` path so they behave
    /// identically), the full library inventory feeds the Libraries tiles (browse
    /// entry points), and each library the user has opted rows into contributes a
    /// block of those rows.
    public struct UnmergedContent: Equatable, Sendable {
        /// Global, cross-server merged Continue Watching (unfiltered; the view
        /// applies Home-visibility just like the merged layout).
        public var continueWatching: [MediaItem]
        /// Global, cross-server merged Recently Added — the same feed merged mode
        /// shows. Rendered as the global "Recently Added" row when the user has
        /// that row enabled (independent of the opt-in per-library "Recently Added
        /// in X" rows).
        public var latest: [MediaItem]
        /// Global, cross-server merged Watchlist.
        public var watchlist: [MediaItem]
        /// Full (Home-eligible, music-excluded) library inventory — feeds the
        /// Libraries tiles so the user can browse into any library's grid.
        public var libraries: [AggregatedLibrary]
        /// Per-library section blocks for libraries the user opted rows into, in
        /// inventory order. Empty blocks (no enabled/non-empty rows) are dropped.
        public var librarySections: [HomeLibrarySectionGroup]

        public init(
            continueWatching: [MediaItem] = [],
            latest: [MediaItem] = [],
            watchlist: [MediaItem] = [],
            libraries: [AggregatedLibrary] = [],
            librarySections: [HomeLibrarySectionGroup] = []
        ) {
            self.continueWatching = continueWatching
            self.latest = latest
            self.watchlist = watchlist
            self.libraries = libraries
            self.librarySections = librarySections
        }

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && watchlist.isEmpty
                && libraries.isEmpty && librarySections.isEmpty
        }
    }

    /// Builds the unmerged Home content. Reuses ``content(from:)`` for the global
    /// rows + full library inventory, then fans out (bounded) over the
    /// visible-on-home libraries to assemble each one's **opted-in** rows:
    ///  - **Recently Added** — the library's newest items (`items(in:)` sorted by
    ///    date added), uniform across providers — when the user enabled it.
    ///  - **Recommended rows** — the provider's native discovery hubs
    ///    (`libraryHubs(...)`, Plex only: "More in Drama", "Because you watched…") —
    ///    when the user enabled them.
    ///
    /// Per-library Continue Watching is intentionally not built here: Continue
    /// Watching is always the single global row (a per-library duplicate is
    /// redundant). A library the user hasn't opted any rows into contributes no
    /// block, so Home stays lean by default. `merged.libraries` still carries the
    /// full inventory for the Libraries tiles (browse entry points).
    public func unmergedContent(
        from accounts: [ResolvedAccount],
        continueWatchingLimit: Int = 20,
        latestLimit: Int = 20,
        watchlistLimit: Int = 20,
        perLibraryLimit: Int = 20,
        visibility: HomeLibraryVisibility = .default,
        identitySources: @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) async -> UnmergedContent {
        // Global rows + full (tagged) library inventory come from the merged path,
        // so Continue Watching / Watchlist stay identical to merged mode.
        let merged = await content(
            from: accounts,
            continueWatchingLimit: continueWatchingLimit,
            latestLimit: latestLimit,
            watchlistLimit: watchlistLimit,
            visibility: visibility,
            identitySources: identitySources
        )

        // Libraries that are visible on Home AND have at least one opted-in row.
        let candidates = merged.libraries.filter { lib in
            visibility.isVisibleOnHome(lib.key)
                && LibraryHomeRowKind.allCases.contains { visibility.isLibraryRowEnabled(lib.key, kind: $0) }
        }
        guard !candidates.isEmpty else {
            return UnmergedContent(
                continueWatching: merged.continueWatching,
                latest: merged.latest,
                watchlist: merged.watchlist,
                libraries: merged.libraries,
                librarySections: []
            )
        }

        let providerByAccount = Dictionary(
            accounts.map { ($0.account.id, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        )

        // Bounded per-library fan-out (reuses the account limiter's cap) so many
        // libraries don't storm the network / decode pipeline at once. Order is
        // preserved; a library whose fetches all fail contributes no block.
        let groups = await Self.loadBounded(candidates) { aggregated -> HomeLibrarySectionGroup? in
            guard let provider = providerByAccount[aggregated.accountID] else { return nil }
            let sections = await Self.librarySections(
                for: aggregated,
                provider: provider,
                perLibraryLimit: perLibraryLimit,
                visibility: visibility
            )
            guard !sections.isEmpty else { return nil }
            return HomeLibrarySectionGroup(library: aggregated, sections: sections)
        }

        return UnmergedContent(
            continueWatching: merged.continueWatching,
            latest: merged.latest,
            watchlist: merged.watchlist,
            libraries: merged.libraries,
            librarySections: groups.compactMap { $0 }
        )
    }

    /// Assembles one library's **opted-in** rows: Recently Added (`items(in:)`) and
    /// the provider's discovery hubs — each only when the user enabled it, so only
    /// enabled rows are fetched. Items are tagged with the owning account/library
    /// so selection routes back to the right provider; empty rows are dropped.
    private static func librarySections(
        for aggregated: AggregatedLibrary,
        provider: any MediaProvider,
        perLibraryLimit: Int,
        visibility: HomeLibraryVisibility
    ) async -> [LibrarySection] {
        let accountID = aggregated.accountID
        let libraryID = aggregated.library.id
        let libraryKey = aggregated.key
        let kind = aggregated.library.kind

        let wantsRecentlyAdded = visibility.isLibraryRowEnabled(libraryKey, kind: .recentlyAdded)
        let wantsHubs = visibility.isLibraryRowEnabled(libraryKey, kind: .hubs)

        // Recently Added: the library's newest items, uniform across providers.
        async let recentTask = wantsRecentlyAdded ? (try? provider.items(
            in: libraryID,
            kind: kind,
            page: PageRequest(
                startIndex: 0,
                limit: perLibraryLimit,
                sort: SortDescriptor(field: .dateAdded, direction: .descending)
            )
        )) : nil
        // Provider-native discovery hubs (Plex only; [] elsewhere).
        async let hubsTask = wantsHubs ? (try? provider.libraryHubs(libraryID: libraryID, kind: kind, limit: perLibraryLimit)) : nil

        let recent = ((await recentTask) ?? nil)?.items ?? []
        let hubs = ((await hubsTask) ?? nil) ?? []

        func tag(_ items: [MediaItem]) -> [MediaItem] {
            items.map { $0.taggingSource(accountID).taggingLibrary(libraryID) }
        }

        var sections: [LibrarySection] = []
        let recentTagged = tag(recent)
        if !recentTagged.isEmpty {
            sections.append(LibrarySection(
                id: "recentlyAdded",
                title: "Recently Added in \(aggregated.library.title)",
                style: .poster,
                items: recentTagged
            ))
        }
        // Plex hubs already carry their own titles/ids; tag their items for routing.
        for hub in hubs where !hub.items.isEmpty {
            sections.append(LibrarySection(
                id: hub.id,
                title: hub.title,
                style: hub.style,
                items: tag(hub.items)
            ))
        }
        return sections
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
                // Stop spooling up the remaining accounts once the aggregation has
                // been cancelled (Home dismissed / re-triggered). Without this the
                // window keeps refilling and fires a fetch for every remaining
                // account even though nobody is waiting for the result.
                if nextIndex < accounts.count, !Task.isCancelled {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let resolved = accounts[queuedIndex]
                    group.addTask { (queuedIndex, await operation(resolved)) }
                }
            }
            return accounts.indices.compactMap { byIndex[$0] }
        }
    }

    /// Generic bounded, order-preserving fan-out over any element list — used by
    /// the unmerged per-library builder so many libraries don't storm the network
    /// at once. Mirrors ``loadPerAccount(_:maxConcurrentAccounts:operation:)`` but
    /// over arbitrary `Element`s, and stops queueing once cancelled.
    private static func loadBounded<Element: Sendable, T: Sendable>(
        _ elements: [Element],
        maxConcurrent: Int = accountFanoutLimit,
        operation: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        guard !elements.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrent, elements.count))
        return await withTaskGroup(of: (Int, T).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let element = elements[index]
                group.addTask { (index, await operation(element)) }
            }

            var byIndex: [Int: T] = [:]
            while let (index, value) = await group.next() {
                byIndex[index] = value
                if nextIndex < elements.count, !Task.isCancelled {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let element = elements[queuedIndex]
                    group.addTask { (queuedIndex, await operation(element)) }
                }
            }
            return elements.indices.compactMap { byIndex[$0] }
        }
    }

    private static func load(
        from resolved: ResolvedAccount,
        continueWatchingLimit: Int,
        latestLimit: Int,
        visibility: HomeLibraryVisibility,
        forceLibraryScoping: Bool = false
    ) async -> AccountContent {
        let accountID = resolved.account.id
        let provider = resolved.provider

        // Take the library-scoped fetch path when either:
        //  - the account has a library that is NOT visible on Home (hidden OR
        //    disabled) — scoping excludes it at the source and stamps `libraryID`
        //    so an unscoped Jellyfin feed can't leak it via the fail-open filter; or
        //  - `forceLibraryScoping` is set (unmerged Home), so EVERY provider's feed
        //    is library-attributed even when nothing is hidden — otherwise Jellyfin
        //    Continue Watching items (no `libraryID` on the unscoped feed) couldn't
        //    be sliced into their per-library rows.
        // When nothing is hidden and scoping isn't forced we keep the original
        // single-shot, fully-concurrent fetch (zero behaviour/performance change).
        let accountHasHidden = visibility.excludedKeys
            .union(visibility.disabledKeys)
            .contains { $0.hasPrefix("\(accountID):") }
        let scopeToVisibleLibraries = forceLibraryScoping || accountHasHidden

        // Libraries and watchlist load independently of the row strategy.
        async let libs = try? provider.libraries()
        async let saved = Self.watchlist(from: provider)

        let cw: [MediaItem]
        let lt: [MediaItem]
        let rawLibs: [MediaLibrary]

        if scopeToVisibleLibraries {
            // Resolve the library list first so the row fetches can be scoped to
            // the *visible* libraries. For providers that can only learn an item's
            // owning library by scoping the fetch (Jellyfin — an episode's
            // ParentId is its season, not its library), this both excludes hidden
            // content at the source and stamps each item's `libraryID`. Providers
            // that tag items by other means (Plex) inherit the unscoped default
            // and rely on the row-level filter.
            rawLibs = (await libs) ?? []
            let visibleLibraryIDs = rawLibs
                .filter { !$0.isMusic && visibility.isVisibleOnHome("\(accountID):\($0.id)") }
                .map(\.id)
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

        // Keep **music** out of the video Home rows. Music has its own tab, so a
        // music album that a provider surfaces in Recently Added / on-deck must not
        // land in Continue Watching or Recently Added. `rawLibs` is already resolved
        // here, so this is a free in-memory filter (no extra request). Items tagged
        // with a music `libraryID` (Plex always tags; Jellyfin tags on the scoped
        // path) are dropped; untagged items stay (fail-open) — the Jellyfin scoped
        // path above additionally excludes music at the source.
        let musicLibraryIDs = Set(rawLibs.filter(\.isMusic).map(\.id))
        let cwFiltered = musicLibraryIDs.isEmpty ? cw : cw.filter { $0.libraryID.map { !musicLibraryIDs.contains($0) } ?? true }
        let ltFiltered = musicLibraryIDs.isEmpty ? lt : lt.filter { $0.libraryID.map { !musicLibraryIDs.contains($0) } ?? true }

        if cwFiltered.isEmpty && ltFiltered.isEmpty && rawLibs.isEmpty {
            PlozzLog.app.error("Aggregation: no content from account \(accountID)")
        }

        return AccountContent(
            continueWatching: cwFiltered.map { $0.taggingSource(accountID) },
            latest: ltFiltered.map { $0.taggingSource(accountID) },
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
    /// When `sortByRecency` is set (the Continue Watching row) the merged result is
    /// stable-sorted by ``sortedByRecency(_:)`` so the row reflects what the user
    /// actually watched last instead of a round-robin interleave that shuffles
    /// between launches. Recency comes straight from each card's `lastPlayedAt`,
    /// which the cross-server merge already folds to the newest timestamp across a
    /// title's servers (``MediaItemMerger`` — most-recent-wins). Untimestamped "Next
    /// Up" cards — which each provider stamps with their series' recency up front,
    /// and which only remain untimestamped when that lookup genuinely fails — keep
    /// their interleave order *after* the timestamped ones (they never inherit a
    /// neighbouring show's timestamp).
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

    /// Stable descending sort of a merged Continue Watching row by `lastPlayedAt`.
    ///
    /// Each card's recency is its own `lastPlayedAt`, which for a cross-server card
    /// the merger already sets to the newest timestamp across every server backing
    /// it (``MediaItemMerger`` — most-recent-wins), and which each provider stamps
    /// onto "Next Up" suggestions from their series' recency before the feed ever
    /// reaches here. Cards we still can't timestamp (a suggestion whose series
    /// recency lookup failed) sort *after* the timestamped ones in their incoming
    /// order — they are never handed a neighbouring show's timestamp.
    ///
    /// The sort is stable (equal `lastPlayedAt` breaks by the original offset) and
    /// idempotent, so re-sorting an already-ordered row leaves it unchanged.
    ///
    /// > Note: an earlier version manufactured recency for untimestamped cards by
    /// > carrying the previous card's timestamp forward through each feed. Because a
    /// > feed is ordered "timestamped first, untimestamped tail" (not
    /// > in-progress/next-up pairs), that let an unrelated show's next episode
    /// > inherit the feed's oldest real timestamp and jump ahead of another server's
    /// > genuine progress — the reported "Continue Watching keeps shifting / isn't
    /// > what I watched last" symptom. Provider-side series stamping now handles the
    /// > legitimate case correctly, so the positional carry-forward was removed.
    static func sortedByRecency(_ items: [MediaItem]) -> [MediaItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastPlayedAt, rhs.element.lastPlayedAt) {
            case let (l?, r?):
                return l == r ? lhs.offset < rhs.offset : l > r
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
