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

    // MARK: audio format hint

    func testAudioFormatHintCombinesCodecAndChannels() {
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "dts", channels: 8, isAtmos: false), "DTS 7.1")
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "truehd", channels: 6, isAtmos: false), "Dolby TrueHD 5.1")
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "ac3", channels: 2, isAtmos: false), "Dolby Digital Stereo")
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "dca", channels: 6, isAtmos: false), "DTS 5.1")
    }

    func testAudioFormatHintAtmosOverridesChannels() {
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "truehd", channels: 8, isAtmos: true), "Dolby Atmos")
    }

    func testAudioFormatHintPartialData() {
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: "eac3", channels: nil, isAtmos: false), "Dolby Digital+")
        XCTAssertEqual(TrackLabeling.audioFormatHint(codec: nil, channels: 6, isAtmos: false), "5.1")
        XCTAssertNil(TrackLabeling.audioFormatHint(codec: nil, channels: nil, isAtmos: false))
        XCTAssertNil(TrackLabeling.audioFormatHint(codec: nil, channels: 0, isAtmos: false))
    }

    func testAudioLabelAppendsFormatToGenericTrack() {
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: "Track 1", language: nil, codec: "dts", channels: 8, trackID: 1),
            "Track 1 (DTS 7.1)"
        )
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: "Track 3", language: "eng", codec: "ac3", channels: 6, trackID: 3),
            "English (Dolby Digital 5.1)"
        )
    }

    func testAudioLabelAppendsCommentary() {
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: "Track 4", language: "eng", codec: "ac3", channels: 2, isCommentary: true, trackID: 4),
            "English (Dolby Digital Stereo, Commentary)"
        )
    }

    func testSubtitleLabelUsesHearingImpairedFlag() {
        // No "SDH" in the title, but the container flag is set.
        XCTAssertEqual(
            TrackLabeling.subtitleLabel(displayTitle: "English", language: "eng", codec: "subrip",
                                        isForced: false, isImageBased: false,
                                        isHearingImpaired: true, trackID: 3),
            "English (SDH)"
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

    // MARK: provider enrichment

    func testEnrichFillsMissingLanguageFromProvider() {
        let engineTrack = MediaTrack(id: 8, kind: .subtitle, displayTitle: "Track 8", language: nil, codec: "pgssub")
        let provider = MediaTrack(id: 8, kind: .subtitle, displayTitle: "Spanish", language: "spa", codec: "pgssub")
        let merged = engineTrack.enriched(withProvider: provider)
        XCTAssertEqual(merged.language, "spa")
    }

    func testEnrichNeverOverwritesRealEngineLanguage() {
        let engineTrack = MediaTrack(id: 3, kind: .subtitle, displayTitle: "Track 3", language: "eng", codec: "subrip")
        let provider = MediaTrack(id: 3, kind: .subtitle, displayTitle: "Spanish", language: "spa")
        let merged = engineTrack.enriched(withProvider: provider)
        XCTAssertEqual(merged.language, "eng")
    }

    func testEnrichAdoptsMeaningfulProviderTitleOverGenericEngineTitle() {
        let engineTrack = MediaTrack(id: 4, kind: .audio, displayTitle: "Track 4", language: nil)
        let provider = MediaTrack(id: 4, kind: .audio, displayTitle: "Director's Commentary", language: nil)
        let merged = engineTrack.enriched(withProvider: provider)
        XCTAssertEqual(merged.displayTitle, "Director's Commentary")
    }

    func testEnrichKeepsEngineTitleWhenProviderTitleIsAlsoGeneric() {
        let engineTrack = MediaTrack(id: 5, kind: .subtitle, displayTitle: "Track 5", language: nil)
        let provider = MediaTrack(id: 5, kind: .subtitle, displayTitle: "Subtitle 5", language: nil)
        let merged = engineTrack.enriched(withProvider: provider)
        XCTAssertEqual(merged.displayTitle, "Track 5")
    }

    func testEnrichWithNoProviderMatchIsUnchanged() {
        let engineTrack = MediaTrack(id: 8, kind: .subtitle, displayTitle: "Track 8", language: nil, codec: "pgssub")
        let merged = engineTrack.enriched(withProvider: nil)
        XCTAssertEqual(merged.language, nil)
        XCTAssertEqual(merged.displayTitle, "Track 8")
    }
}
