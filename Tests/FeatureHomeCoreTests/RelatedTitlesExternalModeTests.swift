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
}
