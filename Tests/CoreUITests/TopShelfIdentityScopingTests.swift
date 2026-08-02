import XCTest
@testable import TopShelfKit

/// The Top Shelf snapshot addressed titles by a bare item id. A Plex `ratingKey` is
/// a small per-server integer, so on a device signed in to two servers two unrelated
/// titles can carry the same one — colliding as tvOS shelf identities, overwriting
/// each other's composited poster files, and producing a deep link that can open the
/// wrong title.
final class TopShelfIdentityScopingTests: XCTestCase {
    func testShelfIdentifierIsAccountScoped() {
        let plex = TopShelfSnapshot.Item(id: "12345", accountID: "plex-1", title: "Dune")
        let jellyfin = TopShelfSnapshot.Item(id: "12345", accountID: "jf-1", title: "Shogun")

        XCTAssertNotEqual(plex.shelfIdentifier, jellyfin.shelfIdentifier)
    }

    /// A snapshot written by an older build has no account and must keep working.
    func testShelfIdentifierFallsBackToTheBareIDWithoutAnAccount() {
        let legacy = TopShelfSnapshot.Item(id: "12345", title: "Dune")
        XCTAssertEqual(legacy.shelfIdentifier, "12345")
    }

    func testDeepLinkCarriesTheAccountAndRoundTrips() {
        let url = TopShelf.itemDeepLink(id: "12345", accountID: "plex-1")
        let reference = TopShelf.itemReference(from: url)

        XCTAssertEqual(reference?.id, "12345")
        XCTAssertEqual(reference?.accountID, "plex-1")
    }

    func testAccountlessDeepLinkStillDecodes() {
        let url = TopShelf.itemDeepLink(id: "12345")
        let reference = TopShelf.itemReference(from: url)

        XCTAssertEqual(reference?.id, "12345")
        XCTAssertNil(reference?.accountID)
        XCTAssertEqual(TopShelf.itemID(from: url), "12345")
    }

    func testForeignURLIsNotAnItemLink() {
        XCTAssertNil(TopShelf.itemReference(from: URL(string: "https://example.com/item/1")!))
    }

    /// An older snapshot on disk must still decode after the field was added.
    func testLegacySnapshotJSONDecodes() throws {
        let json = Data(#"""
        {
          "generatedAt": 0,
          "sections": [
            { "id": "continue", "title": "Continue Watching",
              "items": [{ "id": "12345", "title": "Dune" }] }
          ]
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(TopShelfSnapshot.self, from: json)

        XCTAssertEqual(snapshot.sections.first?.items.first?.shelfIdentifier, "12345")
        XCTAssertNil(snapshot.sections.first?.items.first?.accountID)
    }
}
