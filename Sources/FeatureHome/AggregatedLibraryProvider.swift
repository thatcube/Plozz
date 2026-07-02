import Foundation
import CoreModels

/// One backend source that participates in an aggregated cross-server library
/// browse session: which account, that account's own container id for the
/// library, and the live provider to page it through.
public struct AggregatedLibrarySource: Sendable {
    public let accountID: String
    public let containerID: String
    public let provider: any MediaProvider

    public init(accountID: String, containerID: String, provider: any MediaProvider) {
        self.accountID = accountID
        self.containerID = containerID
        self.provider = provider
    }
}

/// A lightweight `MediaProvider` wrapper that pages a single logical library
/// across several servers and collapses the same title (a movie that lives on
/// both a Plex and a Jellyfin server) into one card — the Library-browse
/// counterpart to the Home-row de-duplication, sharing the exact same
/// ``MediaItemMerger`` identity/merge core so a title appears **once** wherever
/// it is browsed (criterion 1).
///
/// It never walks a whole library: it pulls bounded, index-addressed pages from
/// each source concurrently (`withTaskGroup`), interleaves them, merges, and only
/// fetches further batches when the caller scrolls past what's already merged.
/// Each merged card keeps every server's source ref (via the merger) so tapping
/// it opens a detail view with a working server picker and unified watch-state.
public final class AggregatedLibraryProvider: MediaProvider, @unchecked Sendable {
    public let kind: ProviderKind
    public let session: UserSession

    private let sources: [AggregatedLibrarySource]
    private let cache: Cache

    private actor Cache {
        var merged: [MediaItem] = []
        var offsets: [String: Int] = [:]
        var totals: [String: Int] = [:]
        var exhausted: Set<String> = []
        let serverInfo: [String: SourceServerInfo]
        let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]

        /// Single-flight gate for page-fills. `false` when no fill is running.
        private var fillInProgress = false
        private var fillWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            serverInfo: [String: SourceServerInfo],
            identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
        ) {
            self.serverInfo = serverInfo
            self.identitySources = identitySources
        }

        func initialize(with sourceIDs: [String]) {
            guard offsets.isEmpty else { return }
            for id in sourceIDs { offsets[id] = 0 }
        }

        func offset(for accountID: String) -> Int { offsets[accountID] ?? 0 }
        func setOffset(_ offset: Int, for accountID: String) { offsets[accountID] = offset }
        func setTotal(_ total: Int, for accountID: String) { totals[accountID] = total }
        func markExhausted(_ accountID: String) { exhausted.insert(accountID) }
        func isExhausted(_ accountID: String) -> Bool { exhausted.contains(accountID) }
        func mergedCount() -> Int { merged.count }
        func mergedItems() -> [MediaItem] { merged }

        /// Re-runs the shared cross-server merge over everything seen so far plus
        /// the freshly fetched batch, so duplicates that arrive on a later page
        /// (a title that sorts differently per server) still collapse. Done under
        /// the actor lock so concurrent page requests can't corrupt the buffer.
        func appendMergedBatch(_ items: [MediaItem]) {
            // Re-merges `merged + items` from scratch each page rather than folding
            // the new batch into the existing clusters. This is deliberate: the
            // union-find merge is near-linear per call, and real tvOS browse fills
            // are tens–hundreds of items paged lazily as the user scrolls, so each
            // call is sub-millisecond. An incremental merger would only help a full
            // multi-thousand-item scroll (spread over minutes anyway) and would have
            // to re-implement the same-server two-account dedup and cross-server
            // identity union statefully — trading a proven, correct merge for a
            // subtle one to shave time off a path that is never hot. Kept simple.
            //
            // The `identitySources` closure (an identity-index snapshot lookup) is
            // re-invoked for every already-merged item on each page, so a deep
            // scroll is O(pages × merged) lookups. That is accepted for the same
            // reason: each lookup is a dictionary hit on an immutable snapshot, the
            // merged set only reaches the thousands after minutes of continuous
            // scrolling, and caching per-item results would have to be invalidated
            // whenever the live index warms a new cross-server twin (the very reason
            // the closure is re-consulted). Not worth the staleness risk. (r7-agg-fanout)
            merged = MediaItemMerger.merge(
                merged + items,
                serverInfo: { [serverInfo] id in serverInfo[id] },
                identitySources: identitySources
            )
        }

        func totalUpperBound() -> Int { totals.values.reduce(0, +) }
        func allExhausted(sourceIDs: [String]) -> Bool {
            sourceIDs.allSatisfy { exhausted.contains($0) }
        }

        /// Acquires the page-fill gate, suspending until any in-flight fill
        /// completes. Concurrent `items(...)` calls (tvOS grid prefetch racing a
        /// scroll) would otherwise interleave `fetchNextBatch`'s per-source
        /// offset read → fetch → advance across `await`s, letting one fill jump a
        /// source's offset past a window the other never fetched — a permanent,
        /// invisible page skip (the merge hides the gap). Serializing the fill
        /// makes each read-fetch-advance sequence atomic with respect to others.
        func acquireFill() async {
            while fillInProgress {
                await withCheckedContinuation { fillWaiters.append($0) }
            }
            fillInProgress = true
        }

        /// Releases the gate and wakes the next waiting fill, if any.
        func releaseFill() {
            fillInProgress = false
            if !fillWaiters.isEmpty {
                fillWaiters.removeFirst().resume()
            }
        }
    }

    public init(
        sources: [AggregatedLibrarySource],
        serverInfo: [String: SourceServerInfo] = [:],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) {
        precondition(!sources.isEmpty, "AggregatedLibraryProvider requires at least one source")
        self.sources = sources
        self.cache = Cache(serverInfo: serverInfo, identitySources: identitySources)
        self.kind = sources[0].provider.kind
        self.session = sources[0].provider.session
    }

    // The aggregated provider exists purely to back a cross-server library grid;
    // the Home rows / search / playback all flow through the real per-account
    // providers, so these stay intentionally empty.
    public func libraries() async throws -> [MediaLibrary] { [] }
    public func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    public func latest(limit: Int) async throws -> [MediaItem] { [] }
    public func search(query: String, limit: Int) async throws -> [MediaItem] { [] }

    /// Protocol-conformance fallback only — **not** the routing path for a user
    /// action. The grid pages exclusively through ``items(in:kind:page:)`` (the
    /// only method `LibraryBrowseViewModel` calls on this provider), and every
    /// paged item is tagged with its owning `sourceAccountID`, so tapping a grid
    /// cell opens its detail through the **real per-account provider** (resolved
    /// from that tag), never through this aggregate.
    ///
    /// That invariant matters because a bare `id` is **not globally unique** here:
    /// Plex `ratingKey`s are small per-server integers, so the same `id` can name
    /// *different* titles on two servers. This method can't disambiguate a bare id
    /// (the `MediaProvider` contract gives it no account scope), so it returns the
    /// first source that resolves it — which is only safe *because* nothing on the
    /// user-action path relies on it. If a future caller ever needs id lookup on
    /// the aggregate, the id must be account-scoped (e.g. resolve via the tagged
    /// `sourceAccountID`) rather than passed bare through here.
    public func item(id: String) async throws -> MediaItem {
        for source in sources {
            if let item = try? await source.provider.item(id: id) {
                return item.taggingSource(source.accountID)
            }
        }
        throw AppError.notFound
    }

    /// Protocol-conformance fallback only — see ``item(id:)`` for why a bare id is
    /// not disambiguated here and why that's safe (the grid never routes user
    /// actions through the aggregate).
    public func children(of itemID: String) async throws -> [MediaItem] {
        for source in sources {
            if let children = try? await source.provider.children(of: itemID), !children.isEmpty {
                return children.map { $0.taggingSource(source.accountID) }
            }
        }
        return []
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let sourceIDs = sources.map(\.accountID)
        await cache.initialize(with: sourceIDs)
        let targetCount = page.startIndex + page.limit

        // Serialize the fill: hold the single-flight gate across the whole
        // read-fetch-advance loop AND the merged-buffer snapshot so a concurrent
        // prefetch can't skip a page window nor observe a half-advanced buffer.
        await cache.acquireFill()
        while await cache.mergedCount() < targetCount {
            if await cache.allExhausted(sourceIDs: sourceIDs) { break }
            let fetched = await fetchNextBatch(kind: kind, sort: page.sort, limit: page.limit)
            if fetched.isEmpty { break }
            await cache.appendMergedBatch(fetched)
        }
        let merged = await cache.mergedItems()
        let allExhausted = await cache.allExhausted(sourceIDs: sourceIDs)
        let upperBound = await cache.totalUpperBound()
        await cache.releaseFill()

        let start = min(page.startIndex, merged.count)
        let end = min(start + page.limit, merged.count)
        let pageItems = Array(merged[start..<end])
        // Until every source is drained the true post-merge total is unknown;
        // report an optimistic upper bound (sum of per-server totals) so the grid
        // keeps requesting pages, then settle on the exact merged count.
        let totalCount = allExhausted ? merged.count : max(merged.count, upperBound)

        return MediaPage(items: pageItems, startIndex: page.startIndex, totalCount: totalCount)
    }

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    /// Pulls one bounded page from every not-yet-exhausted source concurrently and
    /// interleaves them, advancing per-source offsets and flagging exhaustion. No
    /// full-library scan: at most `chunkSize` items per source per call.
    private func fetchNextBatch(
        kind: MediaItemKind,
        sort: CoreModels.SortDescriptor,
        limit: Int
    ) async -> [MediaItem] {
        let chunkSize = max(20, limit)

        typealias BatchResult = (accountID: String, page: MediaPage?)
        let results: [BatchResult] = await withTaskGroup(of: BatchResult.self) { group in
            for source in sources {
                group.addTask {
                    if await self.cache.isExhausted(source.accountID) {
                        return (source.accountID, nil)
                    }
                    let offset = await self.cache.offset(for: source.accountID)
                    if let page = try? await source.provider.items(
                        in: source.containerID,
                        kind: kind,
                        page: PageRequest(startIndex: offset, limit: chunkSize, sort: sort)
                    ) {
                        return (source.accountID, page)
                    }
                    return (source.accountID, nil)
                }
            }

            var collected: [BatchResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var grouped: [String: [MediaItem]] = [:]
        for result in results {
            guard let page = result.page else {
                // No page this round: the source was either already exhausted
                // (short-circuited above without a fetch) or hit a transient
                // error / offline blip on this page. Either way, contribute nothing
                // THIS batch but do NOT mark it exhausted — exhaustion is a one-way
                // latch, so silencing a healthy server on a single failed page would
                // drop it from the entire browse session (r8-agg-transient-exhaust).
                // A later batch simply retries it from the same offset. Genuine
                // end-of-list is detected below, only on a SUCCESSFUL page (empty
                // page, or offset past the provider-reported total).
                continue
            }

            let currentOffset = await cache.offset(for: result.accountID)
            let nextOffset = currentOffset + page.items.count
            await cache.setOffset(nextOffset, for: result.accountID)
            await cache.setTotal(page.totalCount, for: result.accountID)
            // Only trust `totalCount` as an end signal when the provider actually
            // reports one (> 0), mirroring `AppState.indexAccount`. A provider that
            // omits the server total falls back to `startIndex + items.count`, so a
            // bare `nextOffset >= totalCount` would mark the source exhausted after
            // the very first page and silently truncate that server's contribution
            // to the grid. An empty page is the reliable cross-provider end signal.
            if page.items.isEmpty || (page.totalCount > 0 && nextOffset >= page.totalCount) {
                await cache.markExhausted(result.accountID)
            }
            grouped[result.accountID] = page.items.map { $0.taggingSource(result.accountID) }
        }

        let orderedGroups = sources.map { grouped[$0.accountID] ?? [] }
        return interleave(orderedGroups)
    }

    private func interleave<T>(_ groups: [[T]]) -> [T] {
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
