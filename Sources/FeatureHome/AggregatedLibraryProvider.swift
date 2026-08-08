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

    /// How many times one fill retries a silent source before emitting past it.
    ///
    /// Emitting past a source is a real (if bounded) cost: the ordered frontier has
    /// moved on, so anything that source contributes later lands at the tail rather
    /// than in its sorted place. That is the right trade against showing nothing —
    /// missing titles are worse than a late run — but it should only happen to a
    /// server that is actually down, never to one that dropped a single request.
    private static let silentAttemptsBeforeSkipping = 2

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

        /// Rebuilds a merger with this session's identity seams — used at init and
        /// whenever the sort changes and the accumulated merge has to be discarded.
        private let makeMerger: () -> IncrementalMediaItemMerger

        init(
            serverInfo: [String: SourceServerInfo],
            identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
            identityRevision: @escaping @Sendable () -> Int
        ) {
            let make = {
                IncrementalMediaItemMerger(
                    serverInfo: { serverInfo[$0] },
                    identitySources: identitySources,
                    identityRevision: identityRevision
                )
            }
            self.makeMerger = make
            self.merger = make()
        }

        /// The sort every piece of retained state was fetched under. All paging
        /// state — offsets, buffers, exhaustion, totals and the running merge — is
        /// only meaningful for ONE ordering, so a changed sort has to throw it away.
        private var activeSort: CoreModels.SortDescriptor?

        func initialize(with sourceIDs: [String]) {
            guard offsets.isEmpty else { return }
            for id in sourceIDs { offsets[id] = 0 }
        }

        /// Resets everything when the caller asks for a different ordering.
        ///
        /// `LibraryBrowseViewModel.setSort` reloads from index 0 against the SAME
        /// provider instance, so without this the aggregate would answer the new
        /// sort out of a buffer built for the old one — a sort menu that appears to
        /// do nothing, or worse, silently mixes two orderings.
        func prepare(for sort: CoreModels.SortDescriptor, sourceIDs: [String]) {
            guard activeSort != sort else { return }
            activeSort = sort
            offsets = Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, 0) })
            totals.removeAll()
            exhausted.removeAll()
            pending.removeAll()
            merger = makeMerger()
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

        // MARK: Ordered k-way merge

        /// Fetched-but-not-yet-emitted items per source, in the server's own order.
        /// A source's head is therefore its smallest remaining item under the
        /// requested sort, which is what makes the merge below correct.
        private var pending: [String: [MediaItem]] = [:]

        func enqueue(_ items: [MediaItem], for sourceKey: String) {
            guard !items.isEmpty else { return }
            pending[sourceKey, default: []].append(contentsOf: items)
        }

        /// Sources that have nothing buffered and more to give — the ones a fill has
        /// to fetch from before it can emit anything else in order.
        func sourcesNeedingFetch(_ sourceKeys: [String]) -> [String] {
            sourceKeys.filter { (pending[$0]?.isEmpty ?? true) && !exhausted.contains($0) }
        }

        /// Pops every item that is *provably* next in the requested order.
        ///
        /// The rule is the classic k-way merge frontier: the globally smallest
        /// buffered head can only be emitted while every source that still has more
        /// to give has something buffered — otherwise an unfetched item from the
        /// empty source might belong before it. When a source runs dry (and isn't
        /// exhausted) the drain stops and the caller fetches more.
        ///
        /// `ordered` is false for sorts `MediaItemSortOrder` can't reproduce
        /// locally (date-added, community rating, random). Those simply drain
        /// everything buffered, round-robin — the pre-existing interleave.
        /// `stalled` names sources that have used up their in-fill retries. They are
        /// NOT exhausted (a later call retries them), but they must not block the
        /// frontier — otherwise one unreachable server would freeze the whole grid
        /// with items already buffered and nothing on screen.
        ///
        /// The cost of stepping over one is that its later arrivals land at the tail
        /// rather than in sorted position, so the grid can end up with a correctly
        /// sorted run followed by a shorter second run. That is deliberate: for a
        /// media browser, being unable to reach a whole server's titles is a worse
        /// failure than a visibly-appended late run, and the retry budget above
        /// keeps it to servers that are genuinely down.
        func drainOrdered(
            sourceKeys: [String],
            sort: CoreModels.SortDescriptor,
            stalled: Set<String> = []
        ) -> [MediaItem] {
            guard MediaItemSortOrder.supportsLocalOrdering(sort.field) else {
                return drainInterleaved(sourceKeys: sourceKeys)
            }
            var emitted: [MediaItem] = []
            while true {
                var bestKey: String?
                var best: MediaItem?
                for key in sourceKeys {
                    guard let queue = pending[key], let head = queue.first else {
                        // A source with more to give but nothing buffered blocks the
                        // frontier: we cannot know whether its next item sorts first.
                        if !exhausted.contains(key), !stalled.contains(key) { return emitted }
                        continue
                    }
                    if best == nil || MediaItemSortOrder.isOrderedBefore(head, best!, sort: sort) {
                        best = head
                        bestKey = key
                    }
                }
                guard let bestKey, best != nil else { return emitted }
                emitted.append(pending[bestKey]!.removeFirst())
            }
        }

        /// Round-robin drain used when the sort can't be reproduced locally.
        private func drainInterleaved(sourceKeys: [String]) -> [MediaItem] {
            var emitted: [MediaItem] = []
            var exhaustedThisPass = false
            while !exhaustedThisPass {
                exhaustedThisPass = true
                for key in sourceKeys where !(pending[key]?.isEmpty ?? true) {
                    emitted.append(pending[key]!.removeFirst())
                    exhaustedThisPass = false
                }
            }
            return emitted
        }

        /// Whether anything at all is still buffered — part of the fill loop's
        /// termination test.
        func hasPending(_ sourceKeys: [String]) -> Bool {
            sourceKeys.contains { !(pending[$0]?.isEmpty ?? true) }
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
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        /// The identity index's publish counter. The running merge re-folds when it
        /// moves, so cards that the index links only *after* they were paged still
        /// collapse — see ``IncrementalMediaItemMerger``. Defaulted for tests and
        /// callers with no index.
        identityRevision: @escaping @Sendable () -> Int = { 0 }
    ) {
        precondition(!sources.isEmpty, "AggregatedLibraryProvider requires at least one source")
        self.sources = sources
        self.cache = Cache(
            serverInfo: serverInfo,
            identitySources: identitySources,
            identityRevision: identityRevision
        )
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
        //
        // Released through `defer` rather than at the exits. Nothing between here
        // and the end of the fill throws today, but the gate has no timeout and no
        // cancellation path: if a future `try` — or an early return added to the
        // loop — ever skipped the release, `fillInProgress` would latch true and
        // EVERY later page would suspend forever with no error and no recovery.
        // That failure is severe enough that the gate must not depend on the
        // control flow staying the way it is today.
        await cache.acquireFill()
        defer { Task { [cache] in await cache.releaseFill() } }
        // A changed sort invalidates every buffered page and the whole running
        // merge. Done inside the gate, so a concurrent prefetch can never observe
        // a half-reset cache or fold a page fetched under the old ordering.
        await cache.prepare(for: page.sort, sourceIDs: sourceIDs)
        /// Sources that have used up their in-fill retries and are being emitted
        /// past. Scoped per call so a blip never persists into the next request.
        var stalled: Set<String> = []
        /// Consecutive silent attempts per source WITHIN this fill.
        var silentAttempts: [String: Int] = [:]
        while await cache.mergedCount() < targetCount {
            let allExhausted = await cache.allExhausted(sourceIDs: sourceIDs)
            let hasPending = await cache.hasPending(sourceIDs)
            if allExhausted, !hasPending { break }

            // Top up only the sources that are actually blocking the merge
            // frontier — a source with a full buffer has nothing to gain from
            // another round-trip, and skipping it is what keeps the read
            // amplification of a many-library browse bounded.
            let hungry = await cache.sourcesNeedingFetch(sourceIDs)
            var progressed = false
            if !hungry.isEmpty {
                let tf = Date()
                let produced = await fetchNextBatch(
                    into: hungry,
                    kind: kind,
                    sort: page.sort,
                    limit: page.limit
                )
                fetchMs += Int(Date().timeIntervalSince(tf) * 1000)
                progressed = !produced.isEmpty
                // A hungry source that answered with nothing is either offline or
                // erroring. Don't let it hold the ordered frontier hostage this
                // call; it stays un-exhausted, so the next page retries it.
                for key in produced { silentAttempts[key] = 0 }
                for key in hungry where !produced.contains(key) {
                    silentAttempts[key, default: 0] += 1
                }
                // Only give up on a source — and start emitting past it, which is
                // what puts its late arrivals out of order — once it has actually
                // been retried. A single dropped request should never cost the
                // grid its ordering.
                stalled = Set(
                    silentAttempts
                        .filter { $0.value >= Self.silentAttemptsBeforeSkipping }
                        .keys
                )
            }

            let tm = Date()
            let ready = await cache.drainOrdered(
                sourceKeys: sourceIDs,
                sort: page.sort,
                stalled: stalled
            )
            if !ready.isEmpty {
                await cache.appendMergedBatch(ready)
                progressed = true
            }
            mergeMs += Int(Date().timeIntervalSince(tm) * 1000)
            // Nothing moved — but a source that still has retry budget is worth one
            // more attempt before we give up and emit past it (or return short).
            let retryable = hungry.contains {
                (silentAttempts[$0] ?? 0) < Self.silentAttemptsBeforeSkipping
            }
            if !progressed, !retryable { break }
        }
        let mergedCount = await cache.mergedCount()
        // Only the requested window is materialized — a deep scroll never copies the
        // whole accumulated buffer just to hand back 60 cards.
        let pageItems = await cache.mergedSlice(from: page.startIndex, limit: page.limit)
        let allExhausted = await cache.allExhausted(sourceIDs: sourceIDs)
        let upperBound = await cache.totalUpperBound()
        // Until every source is drained the true post-merge total is unknown;
        // report an optimistic upper bound (sum of per-server totals) so the grid
        // keeps requesting pages, then settle on the exact merged count.
        //
        // Deliberately NOT padded to keep an unreachable server's slot open. The
        // grid marks a page loaded once it has been served, whatever it contained,
        // so a padded total would render as a permanently empty cell that can never
        // ask again — a visible defect traded for an invisible one. A server that
        // is down when the grid opens simply contributes nothing until the screen
        // is opened again, which is what the single-library browse has always done.
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

    /// Pulls one bounded page from each named source concurrently and buffers it,
    /// advancing per-source offsets and flagging exhaustion. No full-library scan:
    /// at most `chunkSize` items per source per call.
    ///
    /// Returns the sources that actually produced items. The fill loop uses it both
    /// as its progress signal (a round where every request failed must not spin) and
    /// to mark the silent ones as stalled so they stop blocking the ordered merge.
    private func fetchNextBatch(
        into sourceKeys: [String],
        kind: MediaItemKind,
        sort: CoreModels.SortDescriptor,
        limit: Int
    ) async -> Set<String> {
        let chunkSize = max(20, limit)
        let wanted = Set(sourceKeys)
        let targets = sources.filter { wanted.contains($0.sourceKey) }
        guard !targets.isEmpty else { return [] }

        typealias BatchResult = (sourceKey: String, accountID: String, page: MediaPage?)
        let results: [BatchResult] = await withTaskGroup(of: BatchResult.self) { group in
            for source in targets {
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

        var produced: Set<String> = []
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
            guard !page.items.isEmpty else { continue }
            produced.insert(result.sourceKey)
            await cache.enqueue(
                page.items.map { $0.taggingSource(result.accountID) },
                for: result.sourceKey
            )
        }

        return produced
    }
}
