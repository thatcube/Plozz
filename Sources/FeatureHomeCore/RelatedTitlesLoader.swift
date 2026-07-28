import CoreModels
import Foundation
import MetadataKit

/// One entry in the Related row: a title related to the one on screen, plus the
/// viewer's own copy when they have it.
public struct RelatedEntry: Sendable, Equatable, Identifiable {
    public let related: RelatedTitle
    /// The viewer's copy, verified by external id. `nil` when they don't have it.
    public let libraryItem: MediaItem?

    public init(related: RelatedTitle, libraryItem: MediaItem?) {
        self.related = related
        self.libraryItem = libraryItem
    }

    public var id: String { related.id }
    public var isInLibrary: Bool { libraryItem != nil }
    public var title: String { libraryItem?.title ?? related.title }
}

/// Builds the Related row: resolves related titles, then binds each to the
/// viewer's own library.
///
/// Deliberately **library-first in what it shows**. A row of titles the viewer
/// can't play is a row of dead ends, and Plozz has no way to get them — requesting
/// needs Seerr, which is opt-in and most people won't have. So an unmatched title
/// is dropped rather than shown as an unreachable poster.
@MainActor
@Observable
public final class RelatedTitlesLoader {
    public private(set) var entries: [RelatedEntry] = []
    public private(set) var isLoading = false
    /// Whether a load has finished for the current item. Distinguishes "still
    /// working" from "finished, and there is genuinely nothing" — the row reserves
    /// its space for the first and collapses for the second, so the page below it
    /// doesn't jump once results land.
    public private(set) var hasResolved = false

    private let resolver: RelatedTitlesResolver
    private let store: RelatedTitlesStore
    private let search: @Sendable (String, Int) async -> [MediaItem]
    private let now: @Sendable () -> Date
    private var loadedSeedKey: String?

    public init(
        resolver: RelatedTitlesResolver,
        store: RelatedTitlesStore = .shared,
        search: @escaping @Sendable (String, Int) async -> [MediaItem],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.store = store
        self.search = search
        self.now = now
    }

    /// Loads the row for `item`, cache-first.
    ///
    /// Safe to call on every open: a fresh record skips the provider chain
    /// entirely, and re-entering the same page is a no-op.
    public func load(for item: MediaItem) async {
        let query = MetadataQuery(item).seriesScoped
        let key = query.enrichmentCacheKey
        guard loadedSeedKey != key else { return }
        loadedSeedKey = key
        entries = []
        hasResolved = false
        isLoading = true
        defer {
            isLoading = false
            hasResolved = true
        }

        let titles = await resolvedTitles(for: query, key: key)
        guard !titles.isEmpty else { return }
        guard loadedSeedKey == key else { return }  // page changed while resolving
        await matchToLibrary(titles, seedKey: key)
    }

    private func resolvedTitles(for query: MetadataQuery, key: String) async -> [RelatedTitle] {
        if let cached = await store.record(for: key), !cached.isRefreshDue(now: now()) {
            return cached.titles
        }
        let resolved = await resolver.relatedTitles(for: query)
        // An empty answer is cached too, so a title no provider covers doesn't
        // re-run the whole chain on every open.
        await store.store(RelatedTitlesRecord(seedKey: key, titles: resolved, refreshedAt: now()))
        return resolved
    }

    /// Searches for each title and keeps only the id-verified matches.
    ///
    /// Searches run concurrently but are **bounded**: a page opening shouldn't fire
    /// a dozen simultaneous queries at a server that is also streaming video.
    private func matchToLibrary(_ titles: [RelatedTitle], seedKey: String) async {
        let search = self.search
        let ordered = Array(titles.prefix(Self.maximumLookups))
        var matched: [Int: MediaItem] = [:]
        var seenItemIDs = Set<String>()

        await withTaskGroup(of: (Int, MediaItem?).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let related = ordered[index]
                group.addTask {
                    for query in RelatedTitleMatcher.searchQueries(for: related) {
                        let hits = await search(query, Self.searchLimit)
                        if let hit = RelatedTitleMatcher.match(related, in: hits) {
                            return (index, hit)
                        }
                    }
                    return (index, nil)
                }
            }
            while next < min(Self.concurrentLookups, ordered.count) {
                addTask(next)
                next += 1
            }
            for await (index, hit) in group {
                if let hit { matched[index] = hit }
                if next < ordered.count {
                    addTask(next)
                    next += 1
                }
                // Publish as matches land rather than after the last lookup
                // returns. Every candidate costs a search against each server with
                // its own multi-second deadline, so waiting for all of them left the
                // row blank long after the first result was ready — and the row is
                // below the fold, so it fills while the viewer is still reading the
                // synopsis. Rebuilt in candidate order each time, so entries never
                // reshuffle as later ones arrive.
                guard loadedSeedKey == seedKey else { return }
                seenItemIDs.removeAll(keepingCapacity: true)
                entries = ordered.enumerated()
                    .compactMap { index, related -> RelatedEntry? in
                        guard let item = matched[index] else { return nil }
                        guard seenItemIDs.insert(item.id).inserted else { return nil }
                        return RelatedEntry(related: related, libraryItem: item)
                    }
                    .prefix(Self.maximumEntries)
                    .map { $0 }
            }
        }

    }

    /// How many related titles are looked up. Each costs a search per account, so
    /// this is the row's whole cost.
    ///
    /// Comfortably more than the row shows, because a candidate is only kept when
    /// its ids can be verified against the library — and which candidates those are
    /// depends on who catalogued the library. An anime shelf managed by Shoko
    /// verifies TMDb ids and not AniList ones, so a budget sized to the visible row
    /// would be spent entirely on candidates that can never match.
    static let maximumLookups = 24
    /// The most entries the row will show, once matching has filtered the rest.
    static let maximumEntries = 12
    /// Concurrent searches. Enough to fill the row promptly without burying a
    /// server that may also be streaming.
    static let concurrentLookups = 6
    /// Hits per search: a handful is plenty to find an exact id match, and a large
    /// page costs the server real work.
    static let searchLimit = 8
}
