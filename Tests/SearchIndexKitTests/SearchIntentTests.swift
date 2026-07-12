import XCTest
import CoreModels
@testable import SearchIndexKit

final class SearchIntentTests: XCTestCase {
    private let parser = LocalSearchIntentParser()

    func testParsesDescribedEpisodeWithKnownSeries() {
        let intent = parser.parse(
            "the City Friends episode where they wait for dinner",
            knownSeriesTitles: ["City Friends", "Other Show"]
        )
        XCTAssertEqual(intent.kinds, [.episode])
        XCTAssertEqual(intent.seriesTitle, "City Friends")
    }

    func testParsesSeasonEpisodeAndDecade() {
        let intent = parser.parse("sci-fi episode S03E12 from the 1990s")
        XCTAssertEqual(intent.kinds, [.episode])
        XCTAssertEqual(intent.seasonNumber, 3)
        XCTAssertEqual(intent.episodeNumber, 12)
        XCTAssertEqual(intent.minimumYear, 1990)
        XCTAssertEqual(intent.maximumYear, 1999)
        XCTAssertEqual(intent.genres, ["science fiction"])
    }

    func testParsesRuntimeConstraint() {
        let intent = parser.parse("comedy movie under 100 minutes")
        XCTAssertEqual(intent.kinds, [.movie])
        XCTAssertEqual(intent.genres, ["comedy"])
        XCTAssertEqual(intent.runtime?.maximumSeconds, 6_000)
    }
}
