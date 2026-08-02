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
    public var isContinuation: Bool { related.isContinuation }
    public var title: String {  // l10n:content — provider/server-supplied media title
        libraryItem?.title ?? related.title
    }

    /// Library copy when available; otherwise a navigable external discovery
    /// item carrying the provider's ids/artwork.
    public var item: MediaItem {
        if let libraryItem { return libraryItem }
        return MediaItem(
            id: "related:\(related.id)",
            title: related.title,
            kind: related.kind,
            productionYear: related.year,
            posterURL: related.posterURL,
            providerIDs: related.providerIDs,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
    }
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
    public enum DisplayMode: Sendable, Equatable {
        case libraryOnly
        case includeExternal
    }
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
    // Read-only by design: the future unified Plozz identity layer can back this
    // seam with its durable UUID, but merely browsing Related must never allocate
    // or persist identity records.
    private let indexedLibrarySources: @Sendable (MediaItem) -> [MediaSourceRef]
    private let now: @Sendable () -> Date
    private let displayMode: DisplayMode
    private var loadedSeedKey: String?

    public init(
        resolver: RelatedTitlesResolver,
        store: RelatedTitlesStore = .shared,
        search: @escaping @Sendable (String, Int) async -> [MediaItem],
        indexedLibrarySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        displayMode: DisplayMode = .libraryOnly,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.store = store
        self.search = search
        self.indexedLibrarySources = indexedLibrarySources
        self.displayMode = displayMode
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
        // Finalising is guarded on still being the current load. A superseded load
        // can finish first — its searches were already in flight — and an
        // unconditional finish would then mark the NEW page resolved while it is
        // still working, collapsing its placeholder row to nothing.
        defer {
            if loadedSeedKey == key {
                isLoading = false
                hasResolved = true
            }
        }

        let titles = await resolvedTitles(for: query, key: key)
        guard !titles.isEmpty else { return }
        guard loadedSeedKey == key else { return }  // page changed while resolving
        if displayMode == .includeExternal {
            // Resolve against the eager identity index before publishing. Destination
            // routing used to do this only after selection, so an owned title wore an
            // external/requestable mark until it was tapped. The synchronous index
            // lookup keeps this path network-free while making card state and routing
            // agree.
            let capabilities = MediaCapabilities.detected()
            entries = Self.collapsingExternalDuplicates(titles)
                .prefix(Self.maximumEntries)
                .map {
                    RelatedEntry(
                        related: $0,
                        libraryItem: indexedLibraryItem(
                            for: $0,
                            capabilities: capabilities
                        )
                    )
                }
            return
        }
        await matchToLibrary(titles, seedKey: key)
    }

    /// Builds a validated library item from the shared identity index. Related
    /// providers must contribute a strong id: title/year fallback is intentionally
    /// rejected because a wrong ownership match can route playback to another work.
    private func indexedLibraryItem(
        for related: RelatedTitle,
        capabilities: MediaCapabilities
    ) -> MediaItem? {
        let hasStrongIdentity = MediaItemIdentity.strongExternalNamespaces.contains {
            related.providerIDs.providerID($0.namespace) != nil
        }
        guard hasStrongIdentity else { return nil }

        let externalItem = RelatedEntry(related: related, libraryItem: nil).item
        let sources = indexedLibrarySources(externalItem).filter {
            $0.kind == externalItem.kind
        }
        guard let selected = CrossSourceSelector.bestSelection(
            from: sources,
            capabilities: capabilities
        ) else {
            return nil
        }

        var libraryItem = externalItem.selectingSource(selected.source)
        libraryItem.sources = sources
        // `.unknown` describes the metadata provider's view, not the now-validated
        // local copy. Clear it so shared card marks classify this as owned.
        libraryItem.availability = nil
        return libraryItem
    }

    /// Cross-provider Related results often describe the same work under disjoint
    /// ids (AniList vs TMDb). Collapse connected strong-id groups and use an exact
    /// normalized title/year/kind token only to bridge those namespaces.
    static func collapsingExternalDuplicates(
        _ titles: [RelatedTitle]
    ) -> [RelatedTitle] {
        var groups: [(tokens: Set<String>, titles: [RelatedTitle])] = []
        for title in titles {
            let tokens = externalIdentityTokens(for: title)
            var mergedTokens = tokens
            var mergedTitles = [title]
            var matches: [Int] = []
            while true {
                let compatible = groups.indices.filter { index in
                    !matches.contains(index)
                        && !mergedTokens.isDisjoint(with: groups[index].tokens)
                        && groups[index].titles.allSatisfy {
                            canMerge($0, with: mergedTitles)
                        }
                }
                guard !compatible.isEmpty else { break }
                let strong = Set(mergedTokens.filter { $0.hasPrefix("ext:") })
                let next = compatible.first {
                    !strong.isDisjoint(
                        with: Set(
                            groups[$0].tokens.filter { $0.hasPrefix("ext:") }
                        )
                    )
                } ?? compatible[0]
                matches.append(next)
                mergedTokens.formUnion(groups[next].tokens)
                mergedTitles.append(contentsOf: groups[next].titles)
            }
            let orderedMatches = matches.sorted()
            guard let destination = orderedMatches.first else {
                groups.append((tokens, [title]))
                continue
            }
            // Keep provider order stable: existing groups lead, the newly-arrived
            // bridge follows.
            let existingTitles = orderedMatches.flatMap { groups[$0].titles }
            mergedTitles = existingTitles + [title]
            for index in orderedMatches.dropFirst().reversed() {
                groups.remove(at: index)
            }
            groups[destination] = (mergedTokens, mergedTitles)
        }
        return groups.map { mergeExternalGroup($0.titles) }
    }

    private static func canMerge(
        _ candidate: RelatedTitle,
        with existing: [RelatedTitle]
    ) -> Bool {
        for other in existing {
            for entry in MediaItemIdentity.strongExternalNamespaces {
                guard let left = candidate.providerIDs.providerID(entry.namespace),
                      let right = other.providerIDs.providerID(entry.namespace)
                else {
                    continue
                }
                if left.caseInsensitiveCompare(right) != .orderedSame {
                    return false
                }
            }
        }
        return true
    }

    private static func externalIdentityTokens(
        for title: RelatedTitle
    ) -> Set<String> {
        var tokens = Set<String>()
        for entry in MediaItemIdentity.strongExternalNamespaces {
            if let value = title.providerIDs.providerID(entry.namespace) {
                tokens.insert(
                    "ext:\(title.kind.rawValue):\(entry.canonical):\(value.lowercased())"
                )
            }
        }
        if let year = title.year {
            let normalized = MediaItemIdentity.normalizedTitle(title.title)
            if !normalized.isEmpty {
                tokens.insert(
                    "title:\(title.kind.rawValue):\(normalized):\(year)"
                )
            }
        }
        if tokens.isEmpty { tokens.insert("id:\(title.id)") }
        return tokens
    }

    private static func mergeExternalGroup(
        _ titles: [RelatedTitle]
    ) -> RelatedTitle {
        let first = titles[0]
        var providerIDs = first.providerIDs
        for title in titles.dropFirst() {
            for (key, value) in title.providerIDs where providerIDs[key] == nil {
                providerIDs[key] = value
            }
        }
        let relation = titles.map(\.relation).min {
            relationRank($0) < relationRank($1)
        } ?? first.relation
        return RelatedTitle(
            title: first.title,
            year: first.year ?? titles.lazy.compactMap(\.year).first,
            kind: first.kind,
            relation: relation,
            providerIDs: providerIDs,
            posterURL: first.posterURL
                ?? titles.lazy.compactMap(\.posterURL).first,
            source: first.source
        )
    }

    private static func relationRank(
        _ relation: RelatedTitle.Relation
    ) -> Int {
        switch relation {
        case .continuation: return 0
        case .sideStory: return 1
        case .recommendation: return 2
        }
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
        let clock = ContinuousClock()
        var lastPublish = clock.now
        var completed = 0

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
                completed += 1
                // Navigating away must stop the remaining searches, not just discard
                // their results: each is a real query against every signed-in server,
                // and a viewer moving through pages would otherwise leave a growing
                // pile of them competing with the page actually on screen.
                guard loadedSeedKey == seedKey else {
                    group.cancelAll()
                    return
                }
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
                //
                // But publishing on EVERY match costs a full page layout each time.
                // Measured on the Apple TV, a freshly opened series re-laid its
                // detail page six times in a row as this filled in — one per match —
                // which is a large part of why opening a title looked like it was
                // still settling seconds after the push animation ended. Matches
                // arrive in bursts, so coalescing on a short window collapses those
                // six passes into one or two while keeping the row's early fill.
                let now = clock.now
                let isFinalMatch = completed == ordered.count
                guard isFinalMatch || lastPublish.duration(to: now) >= Self.publishInterval else {
                    continue
                }
                lastPublish = now
                seenItemIDs.removeAll(keepingCapacity: true)
                entries = ordered.enumerated()
                    .compactMap { index, related -> RelatedEntry? in
                        let item = matched[index]
                        guard displayMode == .includeExternal || item != nil else {
                            return nil
                        }
                        // Dedupe on identity, not on the server's row id. Two
                        // candidates ("Blade Runner" and "Blade Runner: The Final
                        // Cut", or the same film returned by two providers) can match
                        // to different rows that are the same title, and listing it
                        // twice in a twelve-slot row is a visible bug. Falls back to
                        // the row id when nothing was matched, which is the old
                        // behaviour for unmatched external candidates.
                        let keys: Set<String>
                        if let item {
                            let overlap = MediaItemIdentity.overlapKeys(for: item)
                            keys = overlap.isEmpty ? [item.id] : overlap
                        } else {
                            keys = [related.id]
                        }
                        guard seenItemIDs.isDisjoint(with: keys) else { return nil }
                        seenItemIDs.formUnion(keys)
                        return RelatedEntry(
                            related: related,
                            libraryItem: item
                        )
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
    /// How long to gather freshly matched related titles before republishing the
    /// row. Long enough to collapse a burst of matches into one layout pass,
    /// short enough that the row still fills visibly while the viewer reads the
    /// synopsis. See the publish site for the measurements.
    private static let publishInterval: Duration = .milliseconds(400)

    /// The most entries the row will show, once matching has filtered the rest.
    static let maximumEntries = 12
    /// Concurrent searches. Enough to fill the row promptly without burying a
    /// server that may also be streaming.
    static let concurrentLookups = 6
    /// Hits per search: a handful is plenty to find an exact id match, and a large
    /// page costs the server real work.
    static let searchLimit = 8
}
