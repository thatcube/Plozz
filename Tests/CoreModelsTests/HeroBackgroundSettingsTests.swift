import XCTest
@testable import CoreModels

final class HeroBackgroundSettingsTests: XCTestCase {
    func testDefaultsAreMutedTrailerOnBothSurfaces() {
        let d = HeroBackgroundSettings.default
        XCTAssertTrue(d.homeTrailerEnabled)
        XCTAssertTrue(d.homeTrailerMuted)
        XCTAssertEqual(d.detailMode, .trailer)
        XCTAssertTrue(d.detailTrailerMuted)
        XCTAssertTrue(d.detailTrailerEnabled)
        XCTAssertFalse(d.themeMusicEnabled)
    }

    func testDetailModesAreMutuallyExclusive() {
        for mode in HeroBackgroundMode.allCases {
            let s = HeroBackgroundSettings(detailMode: mode)
            XCTAssertFalse(
                s.detailTrailerEnabled && s.themeMusicEnabled,
                "Trailer and theme music may never be enabled together on the detail page"
            )
        }
    }

    func testNewFormatRoundTrips() throws {
        let s = HeroBackgroundSettings(
            homeTrailerEnabled: false, homeTrailerMuted: false,
            detailMode: .themeMusic, detailTrailerMuted: false
        )
        let back = try JSONDecoder().decode(
            HeroBackgroundSettings.self, from: JSONEncoder().encode(s)
        )
        XCTAssertEqual(back, s)
    }

    // MARK: Migration from the legacy single-mode shape

    func testLegacyThemeMusicMigratesToDetailOnlyHomeTrailerOff() throws {
        // Old blob: theme music was always a detail-page thing, and the single mode
        // wasn't `.trailer`, so the home trailer should end up OFF.
        let data = Data(#"{"mode":"themeMusic","trailerMuted":false}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s.detailMode, .themeMusic)
        XCTAssertFalse(s.homeTrailerEnabled)
        XCTAssertFalse(s.homeTrailerMuted)
        XCTAssertFalse(s.detailTrailerMuted)
    }

    func testLegacyTrailerMigratesToBothSurfaces() throws {
        let data = Data(#"{"mode":"trailer","trailerMuted":true}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s.detailMode, .trailer)
        XCTAssertTrue(s.homeTrailerEnabled)     // old mode was .trailer
        XCTAssertTrue(s.homeTrailerMuted)
        XCTAssertTrue(s.detailTrailerMuted)
    }

    func testLenientDecodeFallsBackForUnknownMode() throws {
        let data = Data(#"{"mode":"future-mode"}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s, .default)
    }

    func testStoreMigratesExistingThemeMusicOptIn() {
        let suite = "HeroBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ThemeMusicSettings(isEnabled: true, volume: .low)
        defaults.set(
            try! JSONEncoder().encode(legacy),
            forKey: "com.plozz.themeMusicSettings"
        )
        XCTAssertEqual(
            HeroBackgroundSettingsStore(defaults: defaults).load().detailMode,
            .themeMusic
        )
    }
}
