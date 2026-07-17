import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the pure cross-engine subtitle scorer extracted from `PlayerViewModel`.
/// These pin the correspondence rules that keep a viewer's subtitle pick pointing
/// at the right engine track across the provider vs Plozzigen id-spaces: a
/// required language match, tie-breaks on forced / SDH / image-based agreement,
/// and declining on an ambiguous tie.
final class SubtitleMatchScorerTests: XCTestCase {
    private func sub(
        id: Int,
        language: String? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        codec: String? = nil,
        isImageBasedSubtitle: Bool = false
    ) -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "Sub \(id)",
            language: language, codec: codec, isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            isImageBasedSubtitle: isImageBasedSubtitle)
    }

    func testMatchesOnLanguage() {
        let provider = sub(id: 3, language: "en")
        let engine = [sub(id: 10, language: "fr"), sub(id: 11, language: "en")]
        XCTAssertEqual(SubtitleMatchScorer.bestMatch(for: provider, in: engine)?.id, 11)
    }

    func testNoLanguageMatchReturnsNil() {
        let provider = sub(id: 3, language: "de")
        let engine = [sub(id: 10, language: "fr"), sub(id: 11, language: "en")]
        XCTAssertNil(SubtitleMatchScorer.bestMatch(for: provider, in: engine))
    }

    func testForcedFlagBreaksTie() {
        let provider = sub(id: 3, language: "en", isForced: true)
        let engine = [
            sub(id: 10, language: "en", isForced: false),
            sub(id: 11, language: "en", isForced: true)
        ]
        XCTAssertEqual(SubtitleMatchScorer.bestMatch(for: provider, in: engine)?.id, 11)
    }

    func testHearingImpairedBreaksTie() {
        let provider = sub(id: 3, language: "en", isHearingImpaired: true)
        let engine = [
            sub(id: 10, language: "en", isHearingImpaired: false),
            sub(id: 11, language: "en", isHearingImpaired: true)
        ]
        XCTAssertEqual(SubtitleMatchScorer.bestMatch(for: provider, in: engine)?.id, 11)
    }

    func testImageBasedAgreementBreaksTie() {
        let provider = sub(id: 3, language: "en", codec: "pgssub")
        let engine = [
            sub(id: 10, language: "en", codec: "subrip"),
            sub(id: 11, language: "en", codec: "pgssub")
        ]
        XCTAssertEqual(SubtitleMatchScorer.bestMatch(for: provider, in: engine)?.id, 11)
    }

    func testAmbiguousTieDeclines() {
        // Two identical-scoring candidates -> decline rather than guess.
        let provider = sub(id: 3, language: "en")
        let engine = [
            sub(id: 10, language: "en"),
            sub(id: 11, language: "en")
        ]
        XCTAssertNil(SubtitleMatchScorer.bestMatch(for: provider, in: engine))
    }

    func testNoLanguageOnProviderConsidersAllCandidates() {
        // Provider track without a language: language filter is skipped; a single
        // best-scoring candidate still wins.
        let provider = sub(id: 3, language: nil, isForced: true)
        let engine = [
            sub(id: 10, language: "fr", isForced: false),
            sub(id: 11, language: "en", isForced: true)
        ]
        XCTAssertEqual(SubtitleMatchScorer.bestMatch(for: provider, in: engine)?.id, 11)
    }

    func testEmptyEngineTracksReturnsNil() {
        XCTAssertNil(SubtitleMatchScorer.bestMatch(for: sub(id: 3, language: "en"), in: []))
    }
}
