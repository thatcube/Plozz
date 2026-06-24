import XCTest
@testable import CoreModels

/// Coverage for the cross-server fields added to `MediaLibrary` that let the Home
/// aggregator fold the *same* library on several servers into one tile whose
/// browse pages every server (criterion 1, Library-browse half).
final class MediaLibraryCrossServerTests: XCTestCase {

    func testTaggingSourceStampsPrimaryAndContainerMap() {
        let lib = MediaLibrary(id: "movies-jelly", title: "Movies", kind: .movie)
        let tagged = lib.taggingSource("jelly")
        XCTAssertEqual(tagged.sourceAccountID, "jelly")
        XCTAssertEqual(tagged.containerID(forSourceAccountID: "jelly"), "movies-jelly")
        XCTAssertEqual(tagged.allSourceAccountIDs, ["jelly"])
    }

    func testAllSourceAccountIDsIsPrimaryFirstThenAdditionalDeduped() {
        let lib = MediaLibrary(
            id: "m",
            title: "Movies",
            kind: .movie,
            sourceAccountID: "plex",
            additionalSourceAccountIDs: ["jelly", "plex", "emby"]
        )
        XCTAssertEqual(lib.allSourceAccountIDs, ["plex", "jelly", "emby"],
                       "Primary first, duplicates of the primary dropped")
    }

    func testContainerIDLookupPerAccount() {
        let lib = MediaLibrary(
            id: "movies-plex",
            title: "Movies",
            kind: .movie,
            sourceAccountID: "plex",
            additionalSourceAccountIDs: ["jelly"],
            sourceContainerIDByAccount: ["jelly": "movies-jelly"]
        )
        XCTAssertEqual(lib.containerID(forSourceAccountID: "plex"), "movies-plex")
        XCTAssertEqual(lib.containerID(forSourceAccountID: "jelly"), "movies-jelly")
        XCTAssertNil(lib.containerID(forSourceAccountID: "unknown"))
    }

    func testInitSeedsPrimaryContainerMappingWhenMissing() {
        let lib = MediaLibrary(id: "m", title: "Movies", kind: .movie, sourceAccountID: "plex")
        XCTAssertEqual(lib.sourceContainerIDByAccount["plex"], "m")
    }

    func testDecodesLegacyJSONWithoutCrossServerFields() throws {
        // Older cached libraries were encoded before the cross-server fields
        // existed; they must still decode (defaults), keeping persistence stable.
        let legacy = """
        {"id":"m","title":"Movies","kind":"movie","sourceAccountID":"plex"}
        """.data(using: .utf8)!
        let lib = try JSONDecoder().decode(MediaLibrary.self, from: legacy)
        XCTAssertEqual(lib.id, "m")
        XCTAssertEqual(lib.additionalSourceAccountIDs, [])
        XCTAssertEqual(lib.containerID(forSourceAccountID: "plex"), "m",
                       "Primary mapping is reconstructed on decode")
    }

    func testRoundTripsCrossServerFields() throws {
        let lib = MediaLibrary(
            id: "movies-plex",
            title: "Movies",
            kind: .movie,
            sourceAccountID: "plex",
            additionalSourceAccountIDs: ["jelly"],
            sourceContainerIDByAccount: ["jelly": "movies-jelly"]
        )
        let data = try JSONEncoder().encode(lib)
        let decoded = try JSONDecoder().decode(MediaLibrary.self, from: data)
        XCTAssertEqual(decoded, lib)
    }
}
