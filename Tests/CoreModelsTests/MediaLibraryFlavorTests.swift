import XCTest
@testable import CoreModels

/// The glyph a library gets in the navigation. The anime rule is the one worth
/// pinning: it is a *name* match (no backend has an anime collection type), so it
/// has to be strict enough that an ordinary library can't trip it.
final class MediaLibraryFlavorTests: XCTestCase {

    private func library(
        title: String,
        kind: MediaItemKind = .series,
        isMusic: Bool = false,
        synthesized: MediaLibrary.SynthesizedName? = nil
    ) -> MediaLibrary {
        MediaLibrary(
            id: "1",
            title: title,
            kind: kind,
            synthesizedName: synthesized,
            isMusic: isMusic
        )
    }

    func testSynthesizedNameWins() {
        XCTAssertEqual(library(title: "whatever", synthesized: .movies).flavor, .movies)
        XCTAssertEqual(library(title: "whatever", synthesized: .tvShows).flavor, .tvShows)
        XCTAssertEqual(library(title: "whatever", synthesized: .anime).flavor, .anime)
    }

    func testGenericSynthesizedNameFallsThroughToTheOtherSignals() {
        XCTAssertEqual(
            library(title: "Library", kind: .movie, synthesized: .generic).flavor,
            .movies
        )
    }

    func testMusicBeatsKind() {
        XCTAssertEqual(library(title: "Tunes", kind: .movie, isMusic: true).flavor, .music)
    }

    func testKindDecidesWhenNothingElseDoes() {
        XCTAssertEqual(library(title: "Films", kind: .movie).flavor, .movies)
        XCTAssertEqual(library(title: "Shows", kind: .series).flavor, .tvShows)
        XCTAssertEqual(library(title: "Clips", kind: .video).flavor, .photos)
        XCTAssertEqual(library(title: "Stuff", kind: .folder).flavor, .mixed)
    }

    func testAnimeIsMatchedByNameAsAWholeToken() {
        XCTAssertEqual(library(title: "Anime").flavor, .anime)
        XCTAssertEqual(library(title: "anime movies", kind: .movie).flavor, .anime)
        XCTAssertEqual(library(title: "Kids — Anime").flavor, .anime)
        XCTAssertEqual(library(title: "アニメ").flavor, .anime)
    }

    func testAnimeNameMatchDoesNotFireOnSubstrings() {
        XCTAssertEqual(library(title: "Animejo").flavor, .tvShows)
        XCTAssertEqual(library(title: "Animation", kind: .movie).flavor, .movies)
        XCTAssertEqual(library(title: "Animals").flavor, .tvShows)
    }

    func testEveryFlavorHasASymbol() {
        for flavor in MediaLibraryFlavor.allCases {
            XCTAssertFalse(flavor.symbolName.isEmpty)
        }
    }
}
