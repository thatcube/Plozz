import XCTest
@testable import CoreModels

/// Forward/back-compat for the per-profile `SubtitleBehavior`, including the new
/// SDH/Forced accessibility preferences (Phase 2).
final class SubtitleBehaviorPreferenceTests: XCTestCase {
    func testDefaultsAreNonSDHNonForced() {
        let d = SubtitleBehavior.default
        XCTAssertEqual(d.hearingImpairedPreference, .preferNonSDH)
        XCTAssertEqual(d.forcedSearchPreference, .preferNonForced)
        XCTAssertEqual(d.searchPreference, .default)
    }

    func testCodableRoundTripPreservesPreferences() throws {
        let behavior = SubtitleBehavior(
            subtitleMode: .all,
            preferredSubtitleLanguage: "de",
            autoDownloadSubtitles: true,
            hearingImpairedPreference: .onlySDH,
            forcedSearchPreference: .preferForced
        )
        let data = try JSONEncoder().encode(behavior)
        let decoded = try JSONDecoder().decode(SubtitleBehavior.self, from: data)
        XCTAssertEqual(decoded, behavior)
        XCTAssertEqual(decoded.searchPreference.hearingImpaired, .onlySDH)
        XCTAssertEqual(decoded.searchPreference.forced, .preferForced)
    }

    func testDecodesLegacyBlobWithoutNewKeys() throws {
        // A blob persisted before the SDH/Forced keys existed must still decode,
        // defaulting the new preferences.
        let legacy = #"{"subtitleMode":"all","autoDownloadSubtitles":true}"#
        let decoded = try JSONDecoder().decode(SubtitleBehavior.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.autoDownloadSubtitles)
        XCTAssertEqual(decoded.hearingImpairedPreference, .preferNonSDH)
        XCTAssertEqual(decoded.forcedSearchPreference, .preferNonForced)
    }

    func testPlexParameterValuesMirrorPlexLevels() {
        XCTAssertEqual(HearingImpairedPreference.preferNonSDH.plexParameterValue, 0)
        XCTAssertEqual(HearingImpairedPreference.preferSDH.plexParameterValue, 1)
        XCTAssertEqual(HearingImpairedPreference.onlySDH.plexParameterValue, 2)
        XCTAssertEqual(HearingImpairedPreference.onlyNonSDH.plexParameterValue, 3)
        XCTAssertEqual(ForcedSubtitlePreference.preferNonForced.plexParameterValue, 0)
        XCTAssertEqual(ForcedSubtitlePreference.onlyForced.plexParameterValue, 2)
    }

    func testResolvedForcedOnlyForcesOnlyForced() {
        let pref = SubtitleSearchPreference(hearingImpaired: .preferSDH, forced: .preferNonForced)
        XCTAssertEqual(pref.resolvedForcedOnly(mode: .forcedOnly).forced, .onlyForced)
        XCTAssertEqual(pref.resolvedForcedOnly(mode: .forcedOnly).hearingImpaired, .preferSDH)
        XCTAssertEqual(pref.resolvedForcedOnly(mode: .all).forced, .preferNonForced)
    }
}
