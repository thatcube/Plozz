import XCTest
import CoreModels
@testable import SearchIndexKit

final class SearchDocumentTests: XCTestCase {
    func testEpisodeDocumentIncludesSeriesPlotAndPeople() {
        let item = MediaItem(
            id: "episode-1",
            title: "The Empty Table",
            kind: .episode,
            overview: "The group waits all night for a table at a Chinese restaurant.",
            parentTitle: "City Friends",
            seasonNumber: 2,
            episodeNumber: 11,
            productionYear: 1991,
            genres: ["Comedy"],
            people: [
                MediaPerson(id: "actor", name: "Jamie Example", role: "Alex", kind: "Actor")
            ],
            libraryID: "shows"
        )

        let document = SearchDocumentBuilder().document(
            for: item,
            accountID: "account",
            providerUserKey: "user"
        )

        XCTAssertEqual(document.sourceKey, "account:episode-1")
        XCTAssertEqual(document.item.sourceAccountID, "account")
        XCTAssertEqual(document.normalizedParentTitle, "city friends")
        XCTAssertTrue(document.metadataText.contains("Season 2 Episode 11"))
        XCTAssertTrue(document.metadataText.contains("Jamie Example"))
        XCTAssertTrue(document.semanticTexts.contains { $0.contains("Chinese restaurant") })
    }

    func testContentHashIsStableAndChangesWithPlot() {
        let first = MediaItem(id: "1", title: "Pilot", kind: .episode, overview: "A storm arrives.")
        let same = MediaItem(id: "1", title: "Pilot", kind: .episode, overview: "A storm arrives.")
        let changed = MediaItem(id: "1", title: "Pilot", kind: .episode, overview: "The sun returns.")
        let builder = SearchDocumentBuilder()

        let hash1 = builder.document(for: first, accountID: "a", providerUserKey: "u").contentHash
        let hash2 = builder.document(for: same, accountID: "a", providerUserKey: "u").contentHash
        let hash3 = builder.document(for: changed, accountID: "a", providerUserKey: "u").contentHash

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }
}
