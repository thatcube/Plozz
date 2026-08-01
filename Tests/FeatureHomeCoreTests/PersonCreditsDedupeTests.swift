import CoreModels
import XCTest
@testable import FeatureHomeCore

/// Covers the dedupe of a SINGLE server's credits answer.
///
/// The cross-server merge deduped every other server's list against the first
/// one's, but took the first one's raw — so a title one server returned twice
/// reached the row twice. It showed up as Deadpool and Deadpool 2 appearing
/// twice each on Ryan Reynolds' page, both copies carrying an identical
/// `movie|deadpool 2|2018` key, i.e. never compared rather than compared and
/// kept.
@MainActor
final class PersonCreditsDedupeTests: XCTestCase {
    private func movie(
        _ id: String,
        _ title: String,
        year: Int?,
        poster: String? = nil
    ) -> MediaItem {
        var item = MediaItem(id: id, title: title, kind: .movie)
        item.productionYear = year
        item.posterURL = poster.flatMap(URL.init(string:))
        return item
    }

    func testCollapsesTheSameTitleReturnedTwiceByOneServer() {
        // The reported case: one server, one film, two library entries.
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("a", "Deadpool", year: 2016),
            movie("b", "Deadpool 2", year: 2018),
            movie("c", "Deadpool", year: 2016),
            movie("d", "Deadpool 2", year: 2018)
        ])
        XCTAssertEqual(collapsed.map(\.title), ["Deadpool", "Deadpool 2"])
    }

    func testKeepsTheFirstCopySoServerOrderingSurvives() {
        // Which duplicate arrives first is the server's ranking, and the row is
        // ordered from it — so the winner must be the earlier entry.
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("first", "Free Guy", year: 2021),
            movie("second", "Free Guy", year: 2021)
        ])
        XCTAssertEqual(collapsed.map(\.id), ["first"])
    }

    func testTakesALaterCopysArtworkWhenTheWinnerHasNone() {
        // Which copy came first is arbitrary; a poster is not. A row of grey
        // title tiles is worse than either duplicate.
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("a", "IF", year: 2024, poster: nil),
            movie("b", "IF", year: 2024, poster: "https://img.example/if.jpg")
        ])
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].id, "a")
        XCTAssertEqual(collapsed[0].posterURL?.absoluteString, "https://img.example/if.jpg")
    }

    func testDoesNotMergeSameTitleDifferentYear() {
        // Two genuinely different works that share a name must both survive —
        // the same reason the key carries a year at all.
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("a", "Dune", year: 1984),
            movie("b", "Dune", year: 2021)
        ])
        XCTAssertEqual(collapsed.count, 2)
    }

    func testNeverMergesEntriesWithNoYear() {
        // Without a year there is no evidence of sameness, and collapsing would
        // silently drop something the viewer owns. Deliberately kept apart.
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("a", "Untitled Project", year: nil),
            movie("b", "Untitled Project", year: nil)
        ])
        XCTAssertEqual(collapsed.count, 2)
    }

    func testDoesNotMergeAcrossKinds() {
        // TMDb and TheTVDB reuse one id space across films and series, and a
        // remake can share a name with a show — kind has to stay part of the key.
        var series = MediaItem(id: "s", title: "Fargo", kind: .series)
        series.productionYear = 1996
        let collapsed = PersonDetailViewModel.collapsingDuplicates([
            movie("m", "Fargo", year: 1996),
            series
        ])
        XCTAssertEqual(collapsed.count, 2)
    }
}
