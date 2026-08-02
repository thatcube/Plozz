import CoreModels
import Foundation
import MetadataKit
import XCTest
@testable import FeatureHomeCore

/// A provider returning many candidates, for bounding the publish path's work.
private struct BulkRelatedProvider: RelatedTitlesProviding {
    let id: MetadataSource = .tmdb
    let isEnabled = true
    let count: Int

    func relatedTitles(
        for query: MetadataQuery,
        limit: Int
    ) async -> [RelatedTitle] {
        (0..<count).map { index in
            RelatedTitle(
                title: "Candidate \(index)",
                year: 2000 + index,
                kind: .movie,
                providerIDs: ["Tmdb": "\(10_000 + index)"],
                posterURL: nil,
                source: .tmdb
            )
        }
    }
}

/// Counts identity-index lookups so the publish path's work can be bounded.
private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func mark() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct StubRelatedProvider: RelatedTitlesProviding {
    let id: MetadataSource = .tmdb
    let isEnabled = true
    let title: RelatedTitle

    func relatedTitles(
        for query: MetadataQuery,
        limit: Int
    ) async -> [RelatedTitle] {
        [title]
    }
}

private final class SearchCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func mark() {
        lock.lock()
        called = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}

@MainActor
final class RelatedTitlesExternalModeTests: XCTestCase {
    private func related(
        title: String = "Related Movie",
        year: Int? = 2026,
        kind: MediaItemKind = .movie,
        ids: [String: String] = ["Tmdb": "99"]
    ) -> RelatedTitle {
        RelatedTitle(
            title: title,
            year: year,
            kind: kind,
            providerIDs: ids,
            posterURL: URL(string: "https://image.test/99.jpg"),
            source: .tmdb
        )
    }

    private func indexedSources(
        for items: [MediaItem]
    ) -> @Sendable (MediaItem) -> [MediaSourceRef] {
        var byIdentity: [MediaIdentity: [IndexedSource]] = [:]
        for item in items {
            let source = IndexedSource(
                accountID: item.sourceAccountID ?? "library-account",
                itemID: item.id,
                providerKind: .jellyfin,
                kind: item.kind,
                normalizedTitle: MediaItemIdentity.normalizedTitle(item.title),
                year: item.productionYear
            )
            for identity in MediaItemIdentity.identities(for: item) {
                byIdentity[identity, default: []].append(source)
            }
        }
        let snapshot = IdentityIndexSnapshot(byIdentity: byIdentity)
        return { snapshot.sourceRefs(for: $0) }
    }

    private func makeLoader(
        related: RelatedTitle,
        indexedLibrarySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        search: SearchCallFlag = SearchCallFlag()
    ) -> RelatedTitlesLoader {
        RelatedTitlesLoader(
            resolver: RelatedTitlesResolver(
                providers: [StubRelatedProvider(title: related)]
            ),
            store: RelatedTitlesStore(directory: nil),
            search: { _, _ in
                search.mark()
                return []
            },
            indexedLibrarySources: indexedLibrarySources,
            displayMode: .includeExternal
        )
    }

    func testExternalModePublishesWithoutSearchingEveryLibrary() async {
        let search = SearchCallFlag()
        let loader = makeLoader(
            related: related(),
            search: search
        )
        let seed = MediaItem(
            id: "seer:movie:1",
            title: "Seed",
            kind: .movie,
            providerIDs: ["Tmdb": "1"],
            availability: .unknown
        )

        await loader.load(for: seed)

        XCTAssertFalse(search.value)
        XCTAssertEqual(loader.entries.map(\.item.title), ["Related Movie"])
        XCTAssertEqual(loader.entries.first?.item.availability, .unknown)
    }

    func testExternalModeClassifiesOwnedSeriesByStrongID() async {
        let related = related(
            title: "Black Sails",
            year: 2014,
            kind: .series,
            ids: ["Tmdb": "47665"]
        )
        let owned = MediaItem(
            id: "jf-series",
            title: "Black Sails",
            kind: .series,
            productionYear: 2014,
            providerIDs: ["Tmdb": "47665"],
            sourceAccountID: "jellyfin-account"
        )
        let search = SearchCallFlag()
        let loader = makeLoader(
            related: related,
            indexedLibrarySources: indexedSources(for: [owned]),
            search: search
        )

        await loader.load(for: seed())

        XCTAssertFalse(search.value)
        XCTAssertTrue(loader.entries.first?.isInLibrary == true)
        XCTAssertEqual(loader.entries.first?.item.id, "jf-series")
        XCTAssertEqual(loader.entries.first?.item.sourceAccountID, "jellyfin-account")
        XCTAssertTrue(loader.entries.first?.item.locallyValidatedPlayableSource == true)
        XCTAssertNil(loader.entries.first?.item.availability)
        XCTAssertTrue(
            loader.entries.first?.item.ownershipPresentation().canPlay == true
        )
        // Pinned through the ONE shared classifier as well as the item's own
        // fields: `TitleClassifier` is what both shells' cards and detail routing
        // consume, so asserting it here is what guarantees neither tvOS nor
        // iOS/iPadOS can put a request mark on this card.
        guard let item = loader.entries.first?.item else { return XCTFail("no entry") }
        XCTAssertFalse(TitleClassifier.isNotOwnedForBadge(item))
        XCTAssertFalse(TitleClassifier.isDiscoveryRouting(item, identitySources: []))
    }

    func testExternalModeClassifiesOwnedMovieByStrongID() async {
        let owned = MediaItem(
            id: "plex-movie",
            title: "Related Movie",
            kind: .movie,
            productionYear: 2026,
            providerIDs: ["Tmdb": "99"],
            sourceAccountID: "plex-account"
        )
        let loader = makeLoader(
            related: related(),
            indexedLibrarySources: indexedSources(for: [owned])
        )

        await loader.load(for: seed())

        XCTAssertTrue(loader.entries.first?.isInLibrary == true)
        XCTAssertEqual(loader.entries.first?.item.id, "plex-movie")
    }

    func testExternalModeKeepsGenuinelyUnownedTitleExternal() async {
        let loader = makeLoader(related: related())

        await loader.load(for: seed())

        XCTAssertFalse(loader.entries.first?.isInLibrary == true)
        XCTAssertEqual(loader.entries.first?.item.id, "related:\(related().id)")
        XCTAssertFalse(loader.entries.first?.item.locallyValidatedPlayableSource == true)
    }

    func testExternalModeRejectsTitleOnlyNearMatch() async {
        let titleOnly = related(
            title: "Related Movie!",
            kind: .movie,
            ids: [:]
        )
        let owned = MediaItem(
            id: "same-title",
            title: "Related Movie",
            kind: .movie,
            productionYear: 2026,
            sourceAccountID: "library-account"
        )
        let loader = makeLoader(
            related: titleOnly,
            indexedLibrarySources: indexedSources(for: [owned])
        )

        await loader.load(for: seed())

        XCTAssertFalse(loader.entries.first?.isInLibrary == true)
    }

    func testExternalModeScopesSharedTMDbIDByKind() async {
        let series = related(
            title: "Unrelated Series",
            year: 2026,
            kind: .series,
            ids: ["Tmdb": "99"]
        )
        let movie = MediaItem(
            id: "movie-99",
            title: "Related Movie",
            kind: .movie,
            productionYear: 2026,
            providerIDs: ["Tmdb": "99"],
            sourceAccountID: "library-account"
        )
        let loader = makeLoader(
            related: series,
            indexedLibrarySources: indexedSources(for: [movie])
        )

        await loader.load(for: seed())

        XCTAssertFalse(loader.entries.first?.isInLibrary == true)
        XCTAssertEqual(loader.entries.first?.item.kind, .series)
        // The converse, through the same classifier: a title the index cannot
        // vouch for must still read as unowned, so fixing the owned case can never
        // start claiming ownership of everything on the row.
        guard let item = loader.entries.first?.item else { return XCTFail("no entry") }
        XCTAssertTrue(TitleClassifier.isNotOwnedForBadge(item))
    }

    func testSharedShellDisplayModeProducesIdenticalOwnershipClassification() async {
        let owned = MediaItem(
            id: "shared-owned",
            title: "Related Movie",
            kind: .movie,
            productionYear: 2026,
            providerIDs: ["Tmdb": "99"],
            sourceAccountID: "library-account"
        )
        let sources = indexedSources(for: [owned])
        let tvLoader = makeLoader(
            related: related(),
            indexedLibrarySources: sources
        )
        let iOSLoader = makeLoader(
            related: related(),
            indexedLibrarySources: sources
        )

        XCTAssertEqual(
            DetailOpenEnvironment.relatedTitlesDisplayMode(isDiscoveryItem: true),
            .includeExternal
        )
        await tvLoader.load(for: seed())
        await iOSLoader.load(for: seed())

        XCTAssertEqual(tvLoader.entries, iOSLoader.entries)
        XCTAssertTrue(tvLoader.entries.first?.isInLibrary == true)
    }

    private func seed() -> MediaItem {
        MediaItem(
            id: "seer:movie:1",
            title: "Seed",
            kind: .movie,
            providerIDs: ["Tmdb": "1"],
            availability: .unknown
        )
    }

    /// The ownership lookup now runs on the **publish** path, so it has to stay
    /// bounded: once per published entry, never per card render, and never more than
    /// the row can show. A row is at most a dozen posters; a hundred candidates must
    /// not become a hundred component walks.
    ///
    /// This is a thermal guard, not a nicety — the app recently shipped a fix for a
    /// severe overheating bug caused by exactly this shape of unbounded per-item work
    /// inside a publication wave.
    func testExternalModeOwnershipLookupIsBoundedByWhatTheRowCanShow() async {
        let lookups = LookupCounter()
        let loader = RelatedTitlesLoader(
            resolver: RelatedTitlesResolver(providers: [BulkRelatedProvider(count: 100)]),
            store: RelatedTitlesStore(directory: nil),
            search: { _, _ in
                XCTFail("the publish path must never touch a server")
                return []
            },
            indexedLibrarySources: { _ in
                lookups.mark()
                return []
            },
            displayMode: .includeExternal
        )

        await loader.load(for: seed())

        XCTAssertLessThanOrEqual(lookups.value, RelatedTitlesLoader.maximumEntries)
        XCTAssertEqual(loader.entries.count, RelatedTitlesLoader.maximumEntries)
    }

    /// And re-entering the same page must not repeat the work: a second load for the
    /// same seed is a no-op, so scrolling back and forth cannot re-run the lookups or
    /// republish an unchanged row.
    func testReenteringTheSamePageDoesNotRepeatOwnershipLookups() async {
        let lookups = LookupCounter()
        let loader = RelatedTitlesLoader(
            resolver: RelatedTitlesResolver(providers: [BulkRelatedProvider(count: 12)]),
            store: RelatedTitlesStore(directory: nil),
            search: { _, _ in [] },
            indexedLibrarySources: { _ in
                lookups.mark()
                return []
            },
            displayMode: .includeExternal
        )

        await loader.load(for: seed())
        let afterFirst = lookups.value
        let published = loader.entries
        await loader.load(for: seed())

        XCTAssertEqual(lookups.value, afterFirst, "second load must be a no-op")
        XCTAssertEqual(loader.entries, published, "row must not be republished")
    }

    func testExternalModeCollapsesCrossProviderDuplicate() {
        let tmdb = RelatedTitle(
            title: "Frieren: Beyond Journey's End",
            year: 2023,
            kind: .series,
            providerIDs: ["Tmdb": "209867"],
            posterURL: nil,
            source: .tmdb
        )
        let anilist = RelatedTitle(
            title: "Frieren: Beyond Journey's End",
            year: 2023,
            kind: .series,
            relation: .continuation,
            providerIDs: ["AniList": "154587", "Mal": "52991"],
            posterURL: URL(string: "https://image.test/frieren.jpg"),
            source: .anilist
        )

        let collapsed = RelatedTitlesLoader.collapsingExternalDuplicates([
            tmdb,
            anilist,
        ])

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.tmdb), "209867")
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.aniList), "154587")
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.myAnimeList), "52991")
        XCTAssertEqual(collapsed[0].relation, .continuation)
        XCTAssertEqual(
            collapsed[0].posterURL,
            URL(string: "https://image.test/frieren.jpg")
        )
    }

    func testTitleBridgeDoesNotMergeConflictingStrongIDs() {
        let first = RelatedTitle(
            title: "Frozen",
            year: 2010,
            kind: .movie,
            providerIDs: ["Tmdb": "111"],
            source: .tmdb
        )
        let second = RelatedTitle(
            title: "Frozen",
            year: 2010,
            kind: .movie,
            providerIDs: ["Tmdb": "222", "Imdb": "tt222"],
            source: .trakt
        )

        let collapsed = RelatedTitlesLoader.collapsingExternalDuplicates([
            first,
            second,
        ])

        XCTAssertEqual(collapsed.count, 2)
        XCTAssertEqual(
            Set(collapsed.compactMap { $0.providerIDs.providerID(.tmdb) }),
            ["111", "222"]
        )
    }

    func testTransitiveBridgeCannotRejoinConflictingGroups() {
        let first = RelatedTitle(
            title: "Frozen",
            year: 2010,
            kind: .movie,
            providerIDs: ["Tmdb": "111"],
            source: .tmdb
        )
        let conflicting = RelatedTitle(
            title: "Frozen",
            year: 2010,
            kind: .movie,
            providerIDs: ["Tmdb": "222", "Imdb": "tt222"],
            source: .trakt
        )
        let bridge = RelatedTitle(
            title: "Frozen",
            year: 2010,
            kind: .movie,
            providerIDs: ["Imdb": "tt222"],
            source: .anilist
        )

        let collapsed = RelatedTitlesLoader.collapsingExternalDuplicates([
            first,
            conflicting,
            bridge,
        ])

        XCTAssertEqual(collapsed.count, 2)
        XCTAssertFalse(collapsed.contains {
            $0.providerIDs.providerID(.tmdb) == "111"
                && $0.providerIDs.providerID(.imdb) == "tt222"
        })
    }

    func testStrongMatchCanBridgeHigherGroupWithoutInvalidIndices() {
        let romaji = RelatedTitle(
            title: "Sousou no Frieren",
            year: 2023,
            kind: .series,
            providerIDs: ["AniList": "154587", "Mal": "52991"],
            source: .anilist
        )
        let english = RelatedTitle(
            title: "Frieren: Beyond Journey's End",
            year: 2023,
            kind: .series,
            providerIDs: ["Tmdb": "209867"],
            source: .tmdb
        )
        let bridge = RelatedTitle(
            title: "Sousou no Frieren",
            year: 2023,
            kind: .series,
            providerIDs: ["Tmdb": "209867", "Imdb": "tt22248376"],
            source: .trakt
        )

        let collapsed = RelatedTitlesLoader.collapsingExternalDuplicates([
            romaji,
            english,
            bridge,
        ])

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.aniList), "154587")
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.tmdb), "209867")
        XCTAssertEqual(collapsed[0].providerIDs.providerID(.imdb), "tt22248376")
    }
}
