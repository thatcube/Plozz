import CoreModels
import Foundation
import MetadataKit
import XCTest
@testable import FeatureHomeCore

private struct OneRelatedProvider: RelatedTitlesProviding {
    let id: MetadataSource = .tmdb
    let isEnabled = true

    func relatedTitles(
        for query: MetadataQuery,
        limit: Int
    ) async -> [RelatedTitle] {
        [
            RelatedTitle(
                title: "Related Movie",
                year: 2026,
                kind: .movie,
                providerIDs: ["Tmdb": "99"],
                posterURL: URL(string: "https://image.test/99.jpg"),
                source: .tmdb
            )
        ]
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
    func testExternalModePublishesWithoutSearchingEveryLibrary() async {
        let search = SearchCallFlag()
        let loader = RelatedTitlesLoader(
            resolver: RelatedTitlesResolver(
                providers: [OneRelatedProvider()]
            ),
            store: RelatedTitlesStore(directory: nil),
            search: { _, _ in
                search.mark()
                return []
            },
            displayMode: .includeExternal
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
