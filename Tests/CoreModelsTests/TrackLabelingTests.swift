import XCTest
@testable import CoreModels

final class TrackLabelingTests: XCTestCase {

    // MARK: language name resolution

    func testLanguageNameResolvesAlpha2AndAlpha3() {
        XCTAssertEqual(TrackLabeling.languageName(forCode: "en"), "English")
        XCTAssertEqual(TrackLabeling.languageName(forCode: "eng"), "English")
        XCTAssertEqual(TrackLabeling.languageName(forCode: "fra"), "French")
        XCTAssertEqual(TrackLabeling.languageName(forCode: "fre"), "French")
        XCTAssertEqual(TrackLabeling.languageName(forCode: "es"), "Spanish")
    }

    func testLanguageNameRejectsNilEmptyAndUnknown() {
        XCTAssertNil(TrackLabeling.languageName(forCode: nil))
        XCTAssertNil(TrackLabeling.languageName(forCode: ""))
        // "und"/"mis" are placeholders, not real languages → no echoed code.
        XCTAssertNil(TrackLabeling.languageName(forCode: "zzz"))
    }

    // MARK: generic-title detection

    func testGenericTitles() {
        XCTAssertTrue(TrackLabeling.isGenericTitle("Track 8"))
        XCTAssertTrue(TrackLabeling.isGenericTitle("Track 8 (pgssub)"))
        XCTAssertTrue(TrackLabeling.isGenericTitle("Subtitle 3"))
        XCTAssertTrue(TrackLabeling.isGenericTitle("subrip"))
        XCTAssertTrue(TrackLabeling.isGenericTitle("  "))
        XCTAssertTrue(TrackLabeling.isGenericTitle(nil))
    }

    func testMeaningfulTitlesAreNotGeneric() {
        XCTAssertFalse(TrackLabeling.isGenericTitle("English"))
        XCTAssertFalse(TrackLabeling.isGenericTitle("Director Commentary"))
        XCTAssertFalse(TrackLabeling.isGenericTitle("English - Dolby Digital - 5.1"))
    }

    // MARK: subtitle labels

    func testSubtitleLabelUsesResolvedLanguage() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "Track 3", language: "eng", codec: "subrip",
            isForced: false, isImageBased: false, trackID: 3
        )
        XCTAssertEqual(label, "English")
    }

    func testSubtitleLabelAppendsForced() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "English", language: "en", codec: "subrip",
            isForced: true, isImageBased: false, trackID: 1
        )
        XCTAssertEqual(label, "English (Forced)")
    }

    func testSubtitleLabelImageGetsFormatHint() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "Spanish", language: "spa", codec: "pgssub",
            isForced: false, isImageBased: true, trackID: 4
        )
        XCTAssertEqual(label, "Spanish (PGS)")
    }

    func testSubtitleLabelUntaggedImageStaysTrackNumberWithHint() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "Track 8 (pgssub)", language: nil, codec: "pgssub",
            isForced: false, isImageBased: true, trackID: 8
        )
        XCTAssertEqual(label, "Track 8 (PGS)")
    }

    func testSubtitleLabelUsesDetectedLanguageWithAutoMarker() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "Track 2", language: nil, codec: "subrip",
            isForced: false, isImageBased: false, detectedLanguage: "es", trackID: 2
        )
        XCTAssertEqual(label, "Spanish (auto)")
    }

    func testSubtitleLabelPrefersProviderLanguageOverDetected() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "Track 2", language: "en", codec: "subrip",
            isForced: false, isImageBased: false, detectedLanguage: "es", trackID: 2
        )
        XCTAssertEqual(label, "English")
    }

    func testSubtitleLabelDetectsSDHFromTitle() {
        let label = TrackLabeling.subtitleLabel(
            displayTitle: "English (SDH)", language: "en", codec: "subrip",
            isForced: false, isImageBased: false, trackID: 5
        )
        XCTAssertEqual(label, "English (SDH)")
    }

    // MARK: audio labels

    func testAudioLabelKeepsRichProviderTitle() {
        let label = TrackLabeling.audioLabel(
            displayTitle: "English - Dolby Digital - 5.1", language: "en", trackID: 1
        )
        XCTAssertEqual(label, "English - Dolby Digital - 5.1")
    }

    func testAudioLabelReplacesGenericWithLanguage() {
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: "Track 2", language: "fra", trackID: 2),
            "French"
        )
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: "Track 2", language: nil, trackID: 2),
            "Track 2"
        )
    }

    // MARK: preferred-language ordering

    private func sub(_ id: Int, _ lang: String?) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: "T\(id)", language: lang)
    }

    func testSortMovesPreferredLanguageFirstStably() {
        let tracks = [sub(0, "en"), sub(1, "fr"), sub(2, "es"), sub(3, "en")]
        let sorted = tracks.sortedByPreferredLanguage(["es"])
        XCTAssertEqual(sorted.map(\.id), [2, 0, 1, 3])
    }

    func testSortHonoursPriorityOrder() {
        let tracks = [sub(0, "en"), sub(1, "fr"), sub(2, "es")]
        let sorted = tracks.sortedByPreferredLanguage(["fr", "en"])
        XCTAssertEqual(sorted.map(\.id), [1, 0, 2])
    }

    func testSortWithNoPreferencesKeepsOrder() {
        let tracks = [sub(0, "en"), sub(1, "fr"), sub(2, "es")]
        XCTAssertEqual(tracks.sortedByPreferredLanguage([]).map(\.id), [0, 1, 2])
        XCTAssertEqual(tracks.sortedByPreferredLanguage([nil]).map(\.id), [0, 1, 2])
    }

    func testSortFoldsAlpha3PreferenceAgainstAlpha2Tracks() {
        let tracks = [sub(0, "en"), sub(1, "fr")]
        // Preferred given as 3-letter; tracks tagged 2-letter must still match.
        XCTAssertEqual(tracks.sortedByPreferredLanguage(["fra"]).map(\.id), [1, 0])
    }
}
