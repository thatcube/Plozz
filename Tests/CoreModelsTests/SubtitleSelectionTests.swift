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

    func testForcedOnlyDoesNotEnableForeignForcedAgainstAudioLanguage() {
        // The Spider-Man subtitle case: English audio, a Turkish forced track, and a
        // subtitle preference that isn't Turkish. The Turkish forced track must NOT be
        // auto-enabled just because it's the only forced option.
        let candidates = [sub(0, "en"), sub(1, "tr", forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(
                candidates: candidates, mode: .forcedOnly, preferredLanguage: "en", audioLanguage: "en"
            ),
            .none
        )
    }

    func testForcedOnlyEnablesForcedMatchingAudioLanguage() {
        // A forced track in the audio language (English forced under English audio)
        // is the correct forced-subtitle behavior and is auto-enabled.
        let candidates = [sub(0, "en", forced: true), sub(1, "tr", forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(
                candidates: candidates, mode: .forcedOnly, preferredLanguage: "de", audioLanguage: "en"
            ),
            .select(id: 0)
        )
    }

    func testForcedOnlyEnablesUntaggedForcedRegardlessOfAudio() {
        // An untagged forced track can't be proven foreign, so it is still honored.
        let candidates = [sub(0, nil, forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(
                candidates: candidates, mode: .forcedOnly, preferredLanguage: "en", audioLanguage: "en"
            ),
            .select(id: 0)
        )
    }

    func testForcedOnlyUnknownAudioPreservesAnyForcedFallback() {
        // With an unknown audio language the historical "any forced" behavior stands.
        let candidates = [sub(0, "en"), sub(1, "tr", forced: true)]
        XCTAssertEqual(
            SubtitleSelector.decide(
                candidates: candidates, mode: .forcedOnly, preferredLanguage: "en", audioLanguage: nil
            ),
            .select(id: 1)
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
                   deliverySource: .localFile(
                       URL(fileURLWithPath: "/tmp/sub/\(id).vtt")
                   ),
                   isImageBasedSubtitle: false)
    }
    private func imageSub(_ id: Int, _ lang: String?, forced: Bool = false, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: lang ?? "PGS", language: lang,
                   isDefault: isDefault, isForced: forced,
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
        // Plex serves embedded SRT with no sidecar source, but the
        // codec is text, so it must NOT be treated as image-based (which would
        // force the hybrid engine and crash on multichannel → needless transcode).
        let embedded = MediaTrack(id: 2, kind: .subtitle, displayTitle: "English (SRT)",
                                  language: "en", isDefault: true, isForced: false,
                                  isImageBasedSubtitle: false)
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

final class ActiveAudioLanguageTests: XCTestCase {
    private func audio(_ id: Int, _ lang: String?, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .audio, displayTitle: lang ?? "Audio", language: lang, isDefault: isDefault)
    }
    private func sub(_ id: Int, _ lang: String?, forced: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: lang ?? "Sub", language: lang, isForced: forced)
    }

    func testPreferredWinsOverLaggingConfirmedContainerDefault() {
        // The load-time race: the engine's confirmed active id still points at the
        // Turkish container default while the requested original (English) pick is in
        // flight. The requested language, which has a real matching track, must win.
        let tracks = [audio(0, "tr", isDefault: true), audio(1, "en")]
        let lang = tracks.activeAudioLanguage(
            pendingID: nil, confirmedID: 0, preferredLanguages: ["en"]
        )
        XCTAssertEqual(lang, "en")
    }

    func testPendingPickWinsOverEverything() {
        let tracks = [audio(0, "tr", isDefault: true), audio(1, "en")]
        let lang = tracks.activeAudioLanguage(
            pendingID: 1, confirmedID: 0, preferredLanguages: []
        )
        XCTAssertEqual(lang, "en")
    }

    func testConfirmedUsedWhenPreferredHasNoMatchingTrack() {
        // Requested English but the file has no English audio; the engine settles on
        // the confirmed Turkish track, which is what the viewer actually hears.
        let tracks = [audio(0, "tr", isDefault: true), audio(1, "de")]
        let lang = tracks.activeAudioLanguage(
            pendingID: nil, confirmedID: 0, preferredLanguages: ["en"]
        )
        XCTAssertEqual(lang, "tr")
    }

    func testFallsBackToContainerDefaultThenNil() {
        let tracks = [audio(0, "tr", isDefault: true), audio(1, "en")]
        XCTAssertEqual(
            tracks.activeAudioLanguage(pendingID: nil, confirmedID: nil, preferredLanguages: []),
            "tr"
        )
        XCTAssertNil(
            [MediaTrack]().activeAudioLanguage(pendingID: nil, confirmedID: nil, preferredLanguages: [])
        )
    }

    func testForcedForeignSubtitleNotEnabledDuringAudioRace() {
        // End-to-end: English audio requested (original), Turkish container default
        // audio still confirmed for a beat, and a Turkish forced subtitle. The
        // resolved audio language is English, so the Turkish forced sub is NOT
        // auto-enabled under .forcedOnly.
        let audioTracks = [audio(0, "tr", isDefault: true), audio(1, "en")]
        let resolved = audioTracks.activeAudioLanguage(
            pendingID: nil, confirmedID: 0, preferredLanguages: ["en"]
        )
        let subtitles = [sub(10, "tr", forced: true)]
        let decision = subtitles.defaultSubtitleSelection(
            mode: .forcedOnly, preferredLanguage: "en", audioLanguage: resolved
        )
        XCTAssertNil(decision, "A Turkish forced subtitle must not auto-enable under English audio")
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

    // MARK: - SDH / Forced accessibility preference

    private func hi(_ id: String, lang: String?, rating: Double? = nil, downloads: Int? = nil, forced: Bool = false, sdh: Bool = false) -> RemoteSubtitle {
        RemoteSubtitle(id: id, name: id, language: lang, communityRating: rating, downloadCount: downloads, isForced: forced, isHearingImpaired: sdh)
    }

    func testDefaultPreferNonSDHDeRanksHigherRatedSDH() {
        // A higher-rated SDH candidate must NOT win under the default prefer-non-SDH.
        let results = [
            hi("sdh", lang: "eng", rating: 9, sdh: true),
            hi("plain", lang: "eng", rating: 5, sdh: false)
        ]
        XCTAssertEqual(results.bestMatch(forLanguage: "en")?.id, "plain",
                       "prefer-non-SDH default outranks a more-highly-rated SDH sub")
    }

    func testPreferSDHRanksSDHFirst() {
        let results = [
            hi("sdh", lang: "eng", rating: 1, sdh: true),
            hi("plain", lang: "eng", rating: 9, sdh: false)
        ]
        let pref = SubtitleSearchPreference(hearingImpaired: .preferSDH)
        XCTAssertEqual(results.bestMatch(forLanguage: "en", preference: pref)?.id, "sdh")
    }

    func testOnlySDHFiltersOutNonSDH() {
        let results = [
            hi("sdh", lang: "eng", rating: 1, sdh: true),
            hi("plain", lang: "eng", rating: 9, sdh: false)
        ]
        let pref = SubtitleSearchPreference(hearingImpaired: .onlySDH)
        XCTAssertEqual(results.bestMatch(forLanguage: "en", preference: pref)?.id, "sdh")
    }

    func testOnlySDHGracefullyDegradesWhenNoneAreSDH() {
        // No SDH candidates → Only-SDH must not dead-end; fall back to the pool.
        let results = [hi("a", lang: "eng", rating: 5), hi("b", lang: "eng", rating: 9)]
        let pref = SubtitleSearchPreference(hearingImpaired: .onlySDH)
        XCTAssertEqual(results.bestMatch(forLanguage: "en", preference: pref)?.id, "b")
    }

    func testRequireLanguageMatchReturnsNilWhenNoLanguageMatch() {
        let results = [remote("a", lang: "fre", rating: 10)]
        XCTAssertNil(results.bestMatch(forLanguage: "en", requireLanguageMatch: true),
                     "auto-download must not attach a wrong-language sub")
        XCTAssertEqual(results.bestMatch(forLanguage: "en", requireLanguageMatch: false)?.id, "a",
                       "manual/fallback path still returns something")
    }

    func testForcedOnlyModeOverridesForcedPreference() {
        // mode .forcedOnly must win even if the profile prefers non-forced.
        let results = [remote("a", lang: "eng", rating: 9), remote("b", lang: "eng", rating: 1, forced: true)]
        let pref = SubtitleSearchPreference(forced: .preferNonForced)
        XCTAssertEqual(results.bestMatch(forLanguage: "en", mode: .forcedOnly, preference: pref)?.id, "b")
    }

    func testApplyingSortsByPreferenceAndDegrades() {
        let results = [
            hi("plain", lang: "eng", rating: 9, sdh: false),
            hi("sdh", lang: "eng", rating: 1, sdh: true)
        ]
        // Prefer SDH → sdh first, plain still present.
        let ordered = results.applying(SubtitleSearchPreference(hearingImpaired: .preferSDH))
        XCTAssertEqual(ordered.map(\.id), ["sdh", "plain"])
        // Only-SDH with an SDH present → filters to just sdh.
        XCTAssertEqual(results.applying(SubtitleSearchPreference(hearingImpaired: .onlySDH)).map(\.id), ["sdh"])
        // Only-SDH with none SDH → degrade, keep both.
        let nonSDH = [hi("a", lang: "eng", rating: 1), hi("b", lang: "eng", rating: 2)]
        XCTAssertEqual(Set(nonSDH.applying(SubtitleSearchPreference(hearingImpaired: .onlySDH)).map(\.id)), ["a", "b"])
    }

    func testNameSuggestsHearingImpairedWordBoundary() {
        XCTAssertTrue(RemoteSubtitle.nameSuggestsHearingImpaired("Movie.2020.en.SDH.srt"))
        XCTAssertTrue(RemoteSubtitle.nameSuggestsHearingImpaired("Show S01E01 [HI]"))
        XCTAssertTrue(RemoteSubtitle.nameSuggestsHearingImpaired("Episode (hearing impaired)"))
        XCTAssertTrue(RemoteSubtitle.nameSuggestsHearingImpaired("english-cc"))
        // Must NOT false-positive on substrings.
        XCTAssertFalse(RemoteSubtitle.nameSuggestsHearingImpaired("Hindi"))
        XCTAssertFalse(RemoteSubtitle.nameSuggestsHearingImpaired("Ghibli.eng.srt"))
        XCTAssertFalse(RemoteSubtitle.nameSuggestsHearingImpaired("Chino"))
    }
}


final class SubtitleBehaviorTests: XCTestCase {
    func testRoundTripWithSubtitleFields() throws {
        var settings = SubtitleBehavior.default
        settings.autoDownloadSubtitles = true
        settings.subtitleMode = .forcedOnly
        settings.preferredSubtitleLanguage = "fr"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SubtitleBehavior.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDefaultsAreSafe() {
        XCTAssertFalse(SubtitleBehavior.default.autoDownloadSubtitles)
        XCTAssertEqual(SubtitleBehavior.default.subtitleMode, .all)
        XCTAssertNil(SubtitleBehavior.default.preferredSubtitleLanguage)
    }

    func testLegacyCaptionSettingsMigratesIntoSplitModels() throws {
        // A blob persisted by an older build under the legacy CaptionSettings
        // shape, carrying both appearance and behaviour fields.
        let legacyJSON = """
        {"fontScale":1.5,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},
        "backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.5},
        "edgeStyle":"uniform","followsSystemStyle":false,
        "autoDownloadSubtitles":true,"subtitleMode":"forcedOnly",
        "preferredSubtitleLanguage":"fr"}
        """
        let legacy = try JSONDecoder().decode(LegacyCaptionSettings.self, from: Data(legacyJSON.utf8))

        // Behaviour half of the migration.
        let behavior = SubtitleBehavior(from: legacy)
        XCTAssertTrue(behavior.autoDownloadSubtitles)
        XCTAssertEqual(behavior.subtitleMode, .forcedOnly)
        XCTAssertEqual(behavior.preferredSubtitleLanguage, "fr")

        // Appearance half of the migration. The legacy `.uniform` edge folds
        // into the single Outline (border) control (see SubtitleStyle), so the
        // migrated style carries the outline via `border`, not the edge.
        let style = SubtitleStyle(from: legacy)
        XCTAssertEqual(style.fontScale, 1.5)
        XCTAssertEqual(style.edge.style, .none)
        XCTAssertTrue(style.border.isEnabled)
        XCTAssertFalse(style.followsSystemStyle)
    }

    func testLegacyFollowSystemStyleNormalizesToPlozzRendering() throws {
        // The old flag was honoured only on the AVPlayer path and is ignored by
        // Plozz's own overlay renderer, so migration deliberately normalises it to
        // `false` (Plozz owns subtitle appearance everywhere) rather than carrying
        // a legacy `true` that would render inconsistently across the two paths.
        let legacyJSON = """
        {"fontScale":1.0,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},
        "backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.5},
        "edgeStyle":"none","followsSystemStyle":true}
        """
        let legacy = try JSONDecoder().decode(LegacyCaptionSettings.self, from: Data(legacyJSON.utf8))
        let style = SubtitleStyle(from: legacy)
        XCTAssertFalse(style.followsSystemStyle)
    }

    func testLegacyDecodeFallsBackForMissingBehaviourFields() throws {
        // JSON persisted before the subtitle behaviour fields existed: only the
        // old appearance keys are present, so behaviour must fall back to defaults.
        let legacyJSON = """
        {"fontScale":1.5,"textColor":{"red":1,"green":1,"blue":1,"alpha":1},
        "backgroundColor":{"red":0,"green":0,"blue":0,"alpha":0.5},
        "edgeStyle":"uniform","followsSystemStyle":false}
        """
        let legacy = try JSONDecoder().decode(LegacyCaptionSettings.self, from: Data(legacyJSON.utf8))
        let behavior = SubtitleBehavior(from: legacy)

        XCTAssertFalse(behavior.autoDownloadSubtitles)
        XCTAssertEqual(behavior.subtitleMode, .all)
        XCTAssertNil(behavior.preferredSubtitleLanguage)
    }

    func testResolvedPreferredLanguageUsesExplicitChoice() {
        var settings = SubtitleBehavior.default
        settings.preferredSubtitleLanguage = "de"
        XCTAssertEqual(settings.resolvedPreferredLanguage, "de")
    }
}
