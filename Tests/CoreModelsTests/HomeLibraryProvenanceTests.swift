import XCTest
@testable import CoreModels

/// Covers the library-provenance added to `MediaItem`/`MediaSourceRef` so that
/// Home-visibility can suppress a hidden library's items from **every** Home row,
/// not just the Libraries tiles. Pins down: Codable back-compat (older cached
/// JSON has no `libraryID`), the `homeVisibilityLibraryKeys` derivation for
/// single-source and merged cross-server cards, the fail-open / ANY-visible
/// `isVisibleOnHome` rules, and that the merge core preserves each server's
/// `libraryID` on its `MediaSourceRef`.
final class HomeLibraryProvenanceTests: XCTestCase {

    // MARK: Codable back-compat

    func testMediaItemEncodeDecodeRoundTripsLibraryID() throws {
        let item = MediaItem(id: "i1", title: "Dune", kind: .movie,
                             sourceAccountID: "acct", libraryID: "L7")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(decoded.libraryID, "L7")
    }

    func testMediaItemDecodesLegacyJSONWithoutLibraryID() throws {
        // An older cached payload that predates the field must still decode, with
        // libraryID defaulting to nil (→ fail-open / always visible).
        let legacy = #"{"id":"i1","title":"Dune","kind":"movie"}"#
        let decoded = try JSONDecoder().decode(MediaItem.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.libraryID)
    }

    func testMediaSourceRefRoundTripsLibraryID() throws {
        let ref = MediaSourceRef(accountID: "acct", itemID: "x", libraryID: "L3")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(MediaSourceRef.self, from: data)
        XCTAssertEqual(decoded.libraryID, "L3")
    }

    func testMediaSourceRefDecodesLegacyJSONWithoutLibraryID() throws {
        let legacy = #"{"accountID":"acct","itemID":"x","versions":[],"isPlayed":false,"isFavorite":false}"#
        let decoded = try JSONDecoder().decode(MediaSourceRef.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.libraryID)
    }

    // MARK: taggingLibrary

    func testTaggingLibrarySetsIDAndIsAdditive() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie, sourceAccountID: "acct")
        XCTAssertEqual(item.taggingLibrary("L9").libraryID, "L9")
    }

    func testTaggingLibraryWithNilLeavesItemUnchanged() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "acct", libraryID: "L1")
        XCTAssertEqual(item.taggingLibrary(nil).libraryID, "L1")
    }

    // MARK: homeVisibilityLibraryKeys

    func testSingleSourceItemDerivesOneVisibilityKey() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "acct", libraryID: "L1")
        XCTAssertEqual(item.homeVisibilityLibraryKeys, ["acct:L1"])
    }

    func testItemWithoutLibraryHasNoVisibilityKeys() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie, sourceAccountID: "acct")
        XCTAssertTrue(item.homeVisibilityLibraryKeys.isEmpty)
    }

    func testMergedItemUnionsEverySourceLibraryKey() {
        var item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "plex", libraryID: "P1")
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j", libraryID: "J9")
        ]
        XCTAssertEqual(item.homeVisibilityLibraryKeys, ["plex:P1", "jelly:J9"])
    }

    func testMergedItemSkipsSourcesMissingLibraryID() {
        var item = MediaItem(id: "i1", title: "X", kind: .movie)
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j") // no libraryID
        ]
        XCTAssertEqual(item.homeVisibilityLibraryKeys, ["plex:P1"])
    }

    // MARK: isVisibleOnHome

    func testFailOpenWhenNoProvenance() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie, sourceAccountID: "acct")
        // Even an all-hiding predicate keeps an unattributable item visible.
        XCTAssertTrue(item.isVisibleOnHome { _ in false })
    }

    func testHiddenWhenOnlyLibraryIsHidden() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "acct", libraryID: "L1")
        XCTAssertFalse(item.isVisibleOnHome { $0 != "acct:L1" })
    }

    func testVisibleWhenItsLibraryIsVisible() {
        let item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "acct", libraryID: "L1")
        XCTAssertTrue(item.isVisibleOnHome { _ in true })
    }

    func testMergedCardVisibleIfAnyContributingLibraryVisible() {
        var item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "plex", libraryID: "P1")
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j", libraryID: "J9")
        ]
        // Plex library hidden, Jellyfin visible → card still shows (ANY-visible).
        XCTAssertTrue(item.isVisibleOnHome { $0 == "jelly:J9" })
    }

    func testMergedCardHiddenOnlyWhenAllContributingLibrariesHidden() {
        var item = MediaItem(id: "i1", title: "X", kind: .movie,
                             sourceAccountID: "plex", libraryID: "P1")
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j", libraryID: "J9")
        ]
        XCTAssertFalse(item.isVisibleOnHome { _ in false })
    }

    // MARK: Merge preserves per-server provenance

    func testMergePreservesEachServersLibraryID() {
        let plex = MediaItem(id: "p", title: "Heat", kind: .movie, productionYear: 1995,
                             providerIDs: ["Imdb": "tt0113277"],
                             sourceAccountID: "plex", libraryID: "P1")
        let jelly = MediaItem(id: "j", title: "Heat", kind: .movie, productionYear: 1995,
                              providerIDs: ["Imdb": "tt0113277"],
                              sourceAccountID: "jelly", libraryID: "J9")
        let merged = MediaItemMerger.merge([plex, jelly])
        XCTAssertEqual(merged.count, 1, "Same external id must merge into one card")
        let card = merged[0]
        let byAccount = Dictionary(uniqueKeysWithValues: card.sources.map { ($0.accountID, $0.libraryID) })
        XCTAssertEqual(byAccount["plex"], "P1")
        XCTAssertEqual(byAccount["jelly"], "J9")
        // And the derived union covers both libraries so ANY-visible works.
        XCTAssertEqual(card.homeVisibilityLibraryKeys, ["plex:P1", "jelly:J9"])
    }
}
