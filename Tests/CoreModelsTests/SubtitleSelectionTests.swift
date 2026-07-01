import XCTest
@testable import CoreModels

final class SubtitleSelectionTests: XCTestCase {
    private func sub(_ id: Int, _ lang: String?, forced: Bool = false, isDefault: Bool = false) -> SubtitleCandidate {
        SubtitleCandidate(id: id, languageCode: lang, isForced: forced, isDefault: isDefault)
    }

    func testNoCandidatesIsNone() {
        XCTAssertEqual(SubtitleSelector.decide(candidates: [], mode: .all, preferredLanguage: "en"), .none)
    }

    func testOffNeverSelectsEvenWithMatches() {
        // Off must win over any candidate, including a forced or default track in
        // the preferred language.
        let candidates = [sub(0, "en"), sub(1, "en", forced: true), sub(2, "en", isDefault: true)]
        XCTAssertEqual(SubtitleSelector.decide(candidates: candidates, mode: .off, preferredLanguage: "en"), .none)
    }

    func testForcedOnlyPrefersForcedInPreferredLanguage() {
        let candidates = [sub(0, "en"), sub(1, "fr", forced: true), sub(2, "en", forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .forcedOnly, preferredLanguage: "en"),
            .select(id: 2)
        )
    }

    func testForcedOnlyFallsBackToAnyForced() {
        let candidates = [sub(0, "en"), sub(1, "fr", forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .forcedOnly, preferredLanguage: "en"),
            .select(id: 1)
        )
    }

    func testForcedOnlyWithNoForcedIsNone() {
        let candidates = [sub(0, "en"), sub(1, "fr")]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .forcedOnly, preferredLanguage: "en"),
            .none
        )
    }

    func testAllPrefersFullSubtitleInLanguageOverForced() {
        let candidates = [sub(0, "en", forced: true), sub(1, "en")]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .all, preferredLanguage: "en"),
            .select(id: 1)
        )
    }

    func testAllMatchesThreeLetterLanguageCode() {
        let candidates = [sub(0, "fra"), sub(1, "eng")]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .all, preferredLanguage: "en"),
            .select(id: 1)
        )
    }

    func testAllDoesNotSelectTaggedForeignDefaultWhenNoLanguageMatch() {
        // A tagged foreign-language default (German) must NOT be auto-enabled for
        // an English preference — picking a language the viewer didn't ask for is
        // the bug. Leave subtitles off.
        let candidates = [sub(0, "fr"), sub(1, "de", isDefault: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .all, preferredLanguage: "en"),
            .none
        )
    }

    func testAllFallsBackToUntaggedDefaultWhenNoLanguageMatch() {
        // An *untagged* default is the best guess for genuinely untagged content,
        // so it is still honored.
        let candidates = [sub(0, "fr"), sub(1, nil, isDefault: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .all, preferredLanguage: "en"),
            .select(id: 1)
        )
    }

    func testAllWithNoMatchAndNoDefaultIsNone() {
        let candidates = [sub(0, "fr"), sub(1, "de")]
        XCTAssertEqual(
            SubtitleSelector.decide(candidates: candidates, mode: .all, preferredLanguage: "en"),
            .none
        )
    }
}

final class ImageSubtitleRoutingTests: XCTestCase {
    private func textSub(_ id: Int, _ lang: String?, forced: Bool = false, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: lang ?? "Sub", language: lang,
                   isDefault: isDefault, isForced: forced,
                   deliveryURL: URL(string: "https://example.com/sub/\(id).vtt"),
                   isImageBasedSubtitle: false)
    }
    private func imageSub(_ id: Int, _ lang: String?, forced: Bool = false, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: lang ?? "PGS", language: lang,
                   isDefault: isDefault, isForced: forced, deliveryURL: nil,
                   isImageBasedSubtitle: true)
    }

    func testImageOnlySubtitleNeedsHybrid() {
        let tracks = [imageSub(2, "en")]
        XCTAssertTrue(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testTextSubtitleStaysNative() {
        let tracks = [textSub(2, "en")]
        XCTAssertFalse(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testEmbeddedTextSubtitleWithoutDeliveryURLStaysNative() {
        // Plex serves embedded SRT with no sidecar URL: deliveryURL is nil but the
        // codec is text, so it must NOT be treated as image-based (which would
        // force the hybrid engine and crash on multichannel → needless transcode).
        let embedded = MediaTrack(id: 2, kind: .subtitle, displayTitle: "English (SRT)",
                                  language: "en", isDefault: true, isForced: false,
                                  deliveryURL: nil, isImageBasedSubtitle: false)
        XCTAssertFalse([embedded].defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testImageSubtitleWithTextEquivalentStaysNative() {
        // Same language + forced-ness available as text → native can show that.
        let tracks = [imageSub(2, "en"), textSub(3, "en")]
        XCTAssertFalse(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testImageSubtitleWithDifferentLanguageTextStillNeedsHybrid() {
        // The user's language is only available as an image sub.
        let tracks = [imageSub(2, "en"), textSub(3, "fr")]
        XCTAssertTrue(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testNoSubtitleSelectedDoesNotNeedHybrid() {
        // mode .all, no language match, no default → nothing selected.
        let tracks = [imageSub(2, "fr"), imageSub(3, "de")]
        XCTAssertFalse(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }

    func testForcedImageSubtitleNeedsHybridInForcedOnlyMode() {
        let tracks = [textSub(2, "en"), imageSub(3, "en", forced: true)]
        XCTAssertTrue(tracks.defaultSubtitleNeedsHybridEngine(mode: .forcedOnly, preferredLanguage: "en"))
    }

    func testDefaultSubtitleSelectionReturnsChosenTrack() {
        let tracks = [textSub(2, "fr"), imageSub(3, "en")]
        XCTAssertEqual(tracks.defaultSubtitleSelection(mode: .all, preferredLanguage: "en")?.id, 3)
    }

    func testEmptyTracksDoNotNeedHybrid() {
        let tracks: [MediaTrack] = []
        XCTAssertFalse(tracks.defaultSubtitleNeedsHybridEngine(mode: .all, preferredLanguage: "en"))
    }
}

final class LanguageMatchTests: XCTestCase {
    func testMatchesTwoAndThreeLetterCodes() {
        XCTAssertTrue(LanguageMatch.matches("en", "eng"))
        XCTAssertTrue(LanguageMatch.matches("fra", "fre"))
        XCTAssertTrue(LanguageMatch.matches("es", "spa"))
        XCTAssertTrue(LanguageMatch.matches("en-US", "eng"))
    }

    func testDoesNotMatchDifferentLanguages() {
        XCTAssertFalse(LanguageMatch.matches("en", "fr"))
        XCTAssertFalse(LanguageMatch.matches("spa", "deu"))
        XCTAssertFalse(LanguageMatch.matches(nil, "en"))
    }

    func testAlpha3Conversion() {
        XCTAssertEqual(LanguageMatch.alpha3("en"), "eng")
        XCTAssertEqual(LanguageMatch.alpha3("fr"), "fra")
        XCTAssertEqual(LanguageMatch.alpha3("eng"), "eng")
        XCTAssertEqual(LanguageMatch.alpha3("es"), "spa")
    }
}

final class SubtitleSuitabilityTests: XCTestCase {
    private func subtitle(_ lang: String?) -> MediaTrack {
        MediaTrack(id: 1, kind: .subtitle, displayTitle: "Sub", language: lang)
    }

    func testNoSubtitlesIsNotSuitable() {
        let tracks = [MediaTrack(id: 0, kind: .audio, displayTitle: "Audio", language: "en")]
        XCTAssertFalse(tracks.hasSuitableSubtitle(forLanguage: "en"))
    }

    func testMatchingLanguageIsSuitable() {
        XCTAssertTrue([subtitle("eng")].hasSuitableSubtitle(forLanguage: "en"))
    }

    func testNonMatchingLanguageIsNotSuitable() {
        XCTAssertFalse([subtitle("fre")].hasSuitableSubtitle(forLanguage: "en"))
    }

    func testNilLanguageMeansAnySubtitleSuffices() {
        XCTAssertTrue([subtitle("fre")].hasSuitableSubtitle(forLanguage: nil))
    }
}

final class RemoteSubtitleBestMatchTests: XCTestCase {
    private func remote(_ id: String, lang: String?, rating: Double? = nil, downloads: Int? = nil, forced: Bool = false) -> RemoteSubtitle {
        RemoteSubtitle(id: id, name: id, language: lang, communityRating: rating, downloadCount: downloads, isForced: forced)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil([RemoteSubtitle]().bestMatch(forLanguage: "en"))
    }

    func testPrefersMatchingLanguage() {
        let results = [remote("a", lang: "fre", rating: 10), remote("b", lang: "eng", rating: 1)]
        XCTAssertEqual(results.bestMatch(forLanguage: "en")?.id, "b")
    }

    func testRanksByRatingThenDownloads() {
        let results = [
            remote("a", lang: "eng", rating: 8, downloads: 10),
            remote("b", lang: "eng", rating: 9, downloads: 1),
            remote("c", lang: "eng", rating: 9, downloads: 50)
        ]
        XCTAssertEqual(results.bestMatch(forLanguage: "en")?.id, "c")
    }

    func testForcedModePrefersForced() {
        let results = [remote("a", lang: "eng", rating: 9), remote("b", lang: "eng", rating: 1, forced: true)]
        XCTAssertEqual(results.bestMatch(forLanguage: "en", mode: .forcedOnly)?.id, "b")
    }

    func testAllModePrefersNonForced() {
        let results = [remote("a", lang: "eng", rating: 1, forced: true), remote("b", lang: "eng", rating: 1)]
        XCTAssertEqual(results.bestMatch(forLanguage: "en", mode: .all)?.id, "b")
    }
}

final class CaptionSettingsSubtitleTests: XCTestCase {
    func testRoundTripWithSubtitleFields() throws {
        var settings = CaptionSettings.default
        settings.autoDownloadSubtitles = true
        settings.subtitleMode = .forcedOnly
        settings.preferredSubtitleLanguage = "fr"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDefaultsAreSafe() {
        XCTAssertFalse(CaptionSettings.default.autoDownloadSubtitles)
        XCTAssertEqual(CaptionSettings.default.subtitleMode, .all)
        XCTAssertNil(CaptionSettings.default.preferredSubtitleLanguage)
    }

    func testBackwardCompatibleDecodingOfOldSettings() throws {
        // JSON persisted before the subtitle fields existed.
        let legacy = """
        {"fontScale":1.5,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},
        "backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.5},
        "edgeStyle":"uniform","followsSystemStyle":false}
        """
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.fontScale, 1.5)
        XCTAssertEqual(decoded.edgeStyle, .uniform)
        XCTAssertFalse(decoded.followsSystemStyle)
        // New fields fall back to their defaults.
        XCTAssertFalse(decoded.autoDownloadSubtitles)
        XCTAssertEqual(decoded.subtitleMode, .all)
        XCTAssertNil(decoded.preferredSubtitleLanguage)
    }

    func testResolvedPreferredLanguageUsesExplicitChoice() {
        var settings = CaptionSettings.default
        settings.preferredSubtitleLanguage = "de"
        XCTAssertEqual(settings.resolvedPreferredLanguage, "de")
    }
}
