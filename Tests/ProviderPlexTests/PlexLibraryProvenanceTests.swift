import XCTest
import CoreModels
@testable import ProviderPlex

/// Plex carries each on-deck / recently-added item's owning library natively as
/// `librarySectionID`, which equals the section `key` used for `MediaLibrary.id`
/// (and therefore the `"accountID:librarySectionID"` Home-visibility key). These
/// pin down that the DTO decodes it and `map(metadata:)` stamps `MediaItem.libraryID`
/// so Home can filter Plex items everywhere without any extra requests.
final class PlexLibraryProvenanceTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testContinueWatchingStampsLibraryIDFromSectionID() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/onDeck", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"101","type":"movie","title":"Blade Runner","year":1982,
           "librarySectionID":3,"viewOffset":1800000,"duration":7200000}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.first?.libraryID, "3",
                       "Plex onDeck items must carry their librarySectionID as libraryID for Home-visibility")
    }

    func testLatestStampsLibraryIDFromSectionID() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/recentlyAdded", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"r1","type":"movie","title":"Dune","librarySectionID":5}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10)
        XCTAssertEqual(latest.first?.libraryID, "5")
    }

    func testLibraryIDNilWhenSectionIDAbsent() async throws {
        // A feed that omits librarySectionID must leave libraryID nil → fail-open.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/recentlyAdded", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"r2","type":"movie","title":"Arrival"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10)
        XCTAssertNil(latest.first?.libraryID)
    }
}
