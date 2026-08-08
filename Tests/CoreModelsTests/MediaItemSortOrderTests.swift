import XCTest
@testable import CoreModels

/// The local ordering used to k-way-merge pages from many servers into one sorted
/// grid. What matters here is that it is a **total order** (so the merge is
/// stable), that unknown values sink rather than float, and that it is honest
/// about the fields it cannot reproduce.
final class MediaItemSortOrderTests: XCTestCase {

    private func item(
        _ title: String,
        year: Int? = nil,
        runtime: TimeInterval? = nil
    ) -> MediaItem {
        MediaItem(id: title, title: title, kind: .movie, productionYear: year, runtime: runtime)
    }

    private func sorted(_ items: [MediaItem], _ sort: CoreModels.SortDescriptor) -> [String] {
        items
            .sorted { MediaItemSortOrder.isOrderedBefore($0, $1, sort: sort) }
            .map(\.title)
    }

    func testOnlyLocallyReproducibleFieldsAreClaimed() {
        XCTAssertTrue(MediaItemSortOrder.supportsLocalOrdering(.name))
        XCTAssertTrue(MediaItemSortOrder.supportsLocalOrdering(.releaseDate))
        XCTAssertTrue(MediaItemSortOrder.supportsLocalOrdering(.runtime))
        // MediaItem carries neither of these, and random has no order at all.
        XCTAssertFalse(MediaItemSortOrder.supportsLocalOrdering(.dateAdded))
        XCTAssertFalse(MediaItemSortOrder.supportsLocalOrdering(.communityRating))
        XCTAssertFalse(MediaItemSortOrder.supportsLocalOrdering(.random))
    }

    func testNameSortIgnoresCaseDiacriticsAndLeadingArticles() {
        let items = [item("The Matrix"), item("Amélie"), item("avatar"), item("Zodiac")]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .name, direction: .ascending)),
            ["Amélie", "avatar", "The Matrix", "Zodiac"]
        )
    }

    func testNameSortIsNumericallyAware() {
        let items = [item("Rocky 10"), item("Rocky 2"), item("Rocky")]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .name, direction: .ascending)),
            ["Rocky", "Rocky 2", "Rocky 10"]
        )
    }

    func testDescendingNameSortReverses() {
        let items = [item("Alien"), item("Zodiac")]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .name, direction: .descending)),
            ["Zodiac", "Alien"]
        )
    }

    func testReleaseDateSortFallsBackToNameOnATie() {
        let items = [item("Zodiac", year: 2007), item("Alien", year: 2007), item("Dune", year: 2021)]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .releaseDate, direction: .ascending)),
            ["Alien", "Zodiac", "Dune"]
        )
    }

    func testUnknownValuesSinkInBothDirections() {
        let items = [item("NoYear"), item("Old", year: 1980), item("New", year: 2020)]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .releaseDate, direction: .ascending)).last,
            "NoYear"
        )
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .releaseDate, direction: .descending)).last,
            "NoYear"
        )
    }

    func testRuntimeSort() {
        let items = [
            item("Long", runtime: 10_000),
            item("Short", runtime: 60),
            item("Unknown")
        ]
        XCTAssertEqual(
            sorted(items, CoreModels.SortDescriptor(field: .runtime, direction: .ascending)),
            ["Short", "Long", "Unknown"]
        )
    }

    func testOrderIsTotalSoEqualTitlesNeverReportBothDirections() {
        let a = item("Dune", year: 2021)
        let b = item("Dune", year: 2021)
        let sort = CoreModels.SortDescriptor(field: .name, direction: .ascending)
        XCTAssertFalse(MediaItemSortOrder.isOrderedBefore(a, b, sort: sort))
        XCTAssertFalse(MediaItemSortOrder.isOrderedBefore(b, a, sort: sort))
    }
}
