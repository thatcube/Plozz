import XCTest
@testable import ProviderShare
import CoreModels

/// Sidecar subtitle filename parsing (Phase 5): teasing the stem / language /
/// forced / SDH out of a `.srt`/`.ass` filename so it can be matched to a video.
final class ShareSidecarParserTests: XCTestCase {
    func testDetectsSubtitleExtensions() {
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.en.srt"))
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.ass"))
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.VTT"))
        XCTAssertFalse(ShareMediaParser.isSubtitleFile("Movie.mkv"))
        XCTAssertFalse(ShareMediaParser.isSubtitleFile("Movie.sup"), "image sidecars excluded")
    }

    func testParsesLanguageOnly() {
        let s = ShareMediaParser.parseSidecar("The Matrix (1999).en.srt")
        XCTAssertEqual(s?.stem, "The Matrix (1999)")
        XCTAssertEqual(s?.language, "en")
        XCTAssertEqual(s?.isForced, false)
        XCTAssertEqual(s?.isSDH, false)
        XCTAssertEqual(s?.ext, "srt")
    }

    func testParsesForcedAndSDHTokens() {
        let forced = ShareMediaParser.parseSidecar("Dune.2021.en.forced.srt")
        XCTAssertEqual(forced?.stem, "Dune.2021")
        XCTAssertEqual(forced?.language, "en")
        XCTAssertTrue(forced?.isForced ?? false)

        let sdh = ShareMediaParser.parseSidecar("Show.S01E01.eng.sdh.ass")
        XCTAssertEqual(sdh?.stem, "Show.S01E01")
        XCTAssertEqual(sdh?.language, "en", "3-letter code folds to 2-letter")
        XCTAssertTrue(sdh?.isSDH ?? false)
        XCTAssertEqual(sdh?.ext, "ass")
    }

    func testParsesFullLanguageName() {
        let s = ShareMediaParser.parseSidecar("Amelie.French.srt")
        XCTAssertEqual(s?.stem, "Amelie")
        XCTAssertEqual(s?.language, "fr")
    }

    func testNoQualifiersLeavesWholeStem() {
        let s = ShareMediaParser.parseSidecar("Movie.srt")
        XCTAssertEqual(s?.stem, "Movie")
        XCTAssertNil(s?.language)
        XCTAssertFalse(s?.isForced ?? true)
    }

    func testReturnsNilForNonSubtitle() {
        XCTAssertNil(ShareMediaParser.parseSidecar("Movie.mkv"))
    }

    func testVideoStemStripsExtension() {
        XCTAssertEqual(ShareMediaParser.videoStem("The Matrix (1999).mkv"), "The Matrix (1999)")
    }

    func testStemMatchesVideoStem() {
        // The parsed sidecar stem should equal the video stem for same-dir pairing.
        let video = ShareMediaParser.videoStem("The Matrix (1999).mkv")
        let sidecar = ShareMediaParser.parseSidecar("The Matrix (1999).en.srt")
        XCTAssertEqual(sidecar?.stem, video)
    }
}
