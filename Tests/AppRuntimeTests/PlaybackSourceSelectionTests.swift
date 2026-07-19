import XCTest
import CoreModels
@testable import AppRuntime

final class PlaybackSourceSelectionTests: XCTestCase {
    func testPlexDiscoverItemRetargetsToIndexedLocalCopy() {
        let discoverID = "5d7768881999bc0020dc8374"
        let item = MediaItem(
            id: discoverID,
            title: "Movie",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/\(discoverID)"],
            sourceAccountID: "plex-account"
        )
        let local = MediaSourceRef(
            accountID: "plex-account",
            itemID: "46498",
            kind: .movie,
            providerKind: .plex
        )

        let selected = PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: [],
            identitySources: { _ in [local] }
        )

        XCTAssertEqual(selected.id, "46498")
        XCTAssertEqual(selected.sourceAccountID, "plex-account")
        XCTAssertEqual(selected.selectedSourceAccountID, "plex-account")
    }
}
