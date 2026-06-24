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

        init(serverInfo: [String: SourceServerInfo]) {
            self.serverInfo = serverInfo
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
            merged = MediaItemMerger.merge(merged + items, serverInfo: { [serverInfo] id in serverInfo[id] })
        }

        func totalUpperBound() -> Int { totals.values.reduce(0, +) }
        func allExhausted(sourceIDs: [String]) -> Bool {
            sourceIDs.allSatisfy { exhausted.contains($0) }
        }
    }

    public init(
        sources: [AggregatedLibrarySource],
        serverInfo: [String: SourceServerInfo] = [:]
    ) {
        precondition(!sources.isEmpty, "AggregatedLibraryProvider requires at least one source")
        self.sources = sources
        self.cache = Cache(serverInfo: serverInfo)
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

    public func item(id: String) async throws -> MediaItem {
        for source in sources {
            if let item = try? await source.provider.item(id: id) {
                return item.taggingSource(source.accountID)
            }
        }
        throw AppError.notFound
    }

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

        while await cache.mergedCount() < targetCount {
            if await cache.allExhausted(sourceIDs: sourceIDs) { break }
            let fetched = await fetchNextBatch(kind: kind, sort: page.sort, limit: page.limit)
            if fetched.isEmpty { break }
            await cache.appendMergedBatch(fetched)
        }

        let merged = await cache.mergedItems()
        let start = min(page.startIndex, merged.count)
        let end = min(start + page.limit, merged.count)
        let pageItems = Array(merged[start..<end])
        let allExhausted = await cache.allExhausted(sourceIDs: sourceIDs)
        let upperBound = await cache.totalUpperBound()
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
                // A failed/offline source is dropped from this batch but the
                // others still merge, so one slow server never blocks the grid.
                await cache.markExhausted(result.accountID)
                continue
            }

            let currentOffset = await cache.offset(for: result.accountID)
            let nextOffset = currentOffset + page.items.count
            await cache.setOffset(nextOffset, for: result.accountID)
            await cache.setTotal(page.totalCount, for: result.accountID)
            if page.items.isEmpty || nextOffset >= page.totalCount {
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
