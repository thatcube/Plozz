import Foundation
import CoreModels

/// One backend source that participates in an aggregated cross-server library
/// browse session: which account, that account's own container id for the
/// library, and the live provider to page it through.
public struct AggregatedLibrarySource: Sendable {
    public let accountID: String
    public let containerID: String
    public let provider: any MediaProvider
    /// The item kind to page this container with, when it differs from the kind
    /// the caller asks the aggregate for.
    ///
    /// A cross-server browse of ONE library leaves this `nil`: every server's copy
    /// holds the same kind, so the caller's kind is right for all of them. The
    /// combined "All Libraries" browse is the case that needs it — it pages a movie
    /// library and a TV library side by side, and asking a movie section for series
    /// returns nothing on both backends.
    public let kind: MediaItemKind?

    public init(
        accountID: String,
        containerID: String,
        provider: any MediaProvider,
        kind: MediaItemKind? = nil
    ) {
        self.accountID = accountID
        self.containerID = containerID
        self.provider = provider
        self.kind = kind
    }

    /// A key unique to this (account, container) pair. Two libraries on the SAME
    /// account are distinct sources, so the account id alone can't identify one in
    /// the combined browse.
    var sourceKey: String { "\(accountID)\u{1F}\(containerID)" }
}

/// A lightweight `MediaProvider` wrapper that pages several containers as one
/// grid and collapses the same title (a movie that lives on both a Plex and a
/// Jellyfin server) into one card — the Library-browse counterpart to the
/// Home-row de-duplication, sharing the exact same identity/merge core so a title
/// appears **once** wherever it is browsed (criterion 1).
///
/// Two shapes use it:
/// - **one library across several servers** — every source is the same library on
///   a different account, so they all page with the caller's kind; and
/// - **the combined "All Libraries" browse** — sources are different libraries
///   (possibly several on one account, of different kinds), so each declares its
///   own ``AggregatedLibrarySource/kind``.
///
/// Because a source is a (account, container) pair rather than an account, all
/// per-source bookkeeping is keyed by ``AggregatedLibrarySource/sourceKey``: two
/// libraries on one account must page independently.
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
        var offsets: [String: Int] = [:]
        var totals: [String: Int] = [:]
        var exhausted: Set<String> = []

        /// The stateful cross-server merge. Folding each batch in (rather than
        /// re-merging everything every page) is what keeps a deep scroll linear:
        /// only clusters an incoming batch actually touches are re-merged, so a
        /// title already on screen never pays `mergeGroup` again. Identity rules and
        /// output order are byte-for-byte the batch merger's — see
        /// ``IncrementalMediaItemMerger``.
        private var merger: IncrementalMediaItemMerger

        /// Single-flight gate for page-fills. `false` when no fill is running.
        private var fillInProgress = false
        private var fillWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            serverInfo: [String: SourceServerInfo],
            identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
        ) {
            self.merger = IncrementalMediaItemMerger(
                serverInfo: { serverInfo[$0] },
                identitySources: identitySources
            )
        }

        func initialize(with sourceIDs: [String]) {
            guard offsets.isEmpty else { return }
            for id in sourceIDs { offsets[id] = 0 }
        }

        func offset(for sourceKey: String) -> Int { offsets[sourceKey] ?? 0 }
        func setOffset(_ offset: Int, for sourceKey: String) { offsets[sourceKey] = offset }
        func setTotal(_ total: Int, for sourceKey: String) { totals[sourceKey] = total }
        func markExhausted(_ sourceKey: String) { exhausted.insert(sourceKey) }
        func isExhausted(_ sourceKey: String) -> Bool { exhausted.contains(sourceKey) }
        func mergedCount() -> Int { merger.count }
        func mergedSlice(from start: Int, limit: Int) -> [MediaItem] {
            merger.slice(from: start, limit: limit)
        }

        /// Folds the freshly fetched batch into the running merge, so duplicates
        /// that arrive on a later page (a title that sorts differently per server)
        /// still collapse. Done under the actor lock so concurrent page requests
        /// can't corrupt the buffer.
        func appendMergedBatch(_ items: [MediaItem]) {
            merger.append(items)
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
        let sourceIDs = sources.map(\.sourceKey)
        await cache.initialize(with: sourceIDs)
        let targetCount = page.startIndex + page.limit
        let t0 = Date()
        var fetchMs = 0
        var mergeMs = 0

        // Serialize the fill: hold the single-flight gate across the whole
        // read-fetch-advance loop AND the merged-buffer snapshot so a concurrent
        // prefetch can't skip a page window nor observe a half-advanced buffer.
        await cache.acquireFill()
        while await cache.mergedCount() < targetCount {
            if await cache.allExhausted(sourceIDs: sourceIDs) { break }
            let tf = Date()
            let fetched = await fetchNextBatch(kind: kind, sort: page.sort, limit: page.limit)
            fetchMs += Int(Date().timeIntervalSince(tf) * 1000)
            if fetched.isEmpty { break }
            let tm = Date()
            await cache.appendMergedBatch(fetched)
            mergeMs += Int(Date().timeIntervalSince(tm) * 1000)
        }
        let mergedCount = await cache.mergedCount()
        // Only the requested window is materialized — a deep scroll never copies the
        // whole accumulated buffer just to hand back 60 cards.
        let pageItems = await cache.mergedSlice(from: page.startIndex, limit: page.limit)
        let allExhausted = await cache.allExhausted(sourceIDs: sourceIDs)
        let upperBound = await cache.totalUpperBound()
        await cache.releaseFill()

        // Until every source is drained the true post-merge total is unknown;
        // report an optimistic upper bound (sum of per-server totals) so the grid
        // keeps requesting pages, then settle on the exact merged count.
        let totalCount = allExhausted ? mergedCount : max(mergedCount, upperBound)

        if ProcessInfo.processInfo.environment["PLZXPAGE"] == "1" {
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            HandoffDiagnostics.emit("PAGE start=\(page.startIndex) limit=\(page.limit) total=\(totalMs)ms fetch=\(fetchMs)ms merge=\(mergeMs)ms mergedCount=\(mergedCount) sources=\(sourceIDs.count)")
        }

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

        typealias BatchResult = (sourceKey: String, accountID: String, page: MediaPage?)
        let results: [BatchResult] = await withTaskGroup(of: BatchResult.self) { group in
            for source in sources {
                group.addTask {
                    if await self.cache.isExhausted(source.sourceKey) {
                        return (source.sourceKey, source.accountID, nil)
                    }
                    let offset = await self.cache.offset(for: source.sourceKey)
                    if let page = try? await source.provider.items(
                        in: source.containerID,
                        // A combined browse mixes libraries of different kinds, so
                        // each source pages with ITS OWN kind when it declares one.
                        kind: source.kind ?? kind,
                        page: PageRequest(startIndex: offset, limit: chunkSize, sort: sort)
                    ) {
                        return (source.sourceKey, source.accountID, page)
                    }
                    return (source.sourceKey, source.accountID, nil)
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

            let currentOffset = await cache.offset(for: result.sourceKey)
            let nextOffset = currentOffset + page.items.count
            await cache.setOffset(nextOffset, for: result.sourceKey)
            await cache.setTotal(page.totalCount, for: result.sourceKey)
            // Only trust `totalCount` as an end signal when the provider actually
            // reports one (> 0), mirroring `AppState.indexAccount`. A provider that
            // omits the server total falls back to `startIndex + items.count`, so a
            // bare `nextOffset >= totalCount` would mark the source exhausted after
            // the very first page and silently truncate that server's contribution
            // to the grid. An empty page is the reliable cross-provider end signal.
            if page.items.isEmpty || (page.totalCount > 0 && nextOffset >= page.totalCount) {
                await cache.markExhausted(result.sourceKey)
            }
            grouped[result.sourceKey] = page.items.map { $0.taggingSource(result.accountID) }
        }

        let orderedGroups = sources.map { grouped[$0.sourceKey] ?? [] }
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
