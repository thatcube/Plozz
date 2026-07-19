import XCTest
@testable import CoreModels

final class HeroBackgroundSettingsTests: XCTestCase {
    func testDefaultIsMutedTrailer() {
        XCTAssertEqual(HeroBackgroundSettings.default.mode, .trailer)
        XCTAssertTrue(HeroBackgroundSettings.default.trailerMuted)
        XCTAssertTrue(HeroBackgroundSettings.default.trailerAutoplayEnabled)
        XCTAssertFalse(HeroBackgroundSettings.default.themeMusicEnabled)
    }

    func testModesAreMutuallyExclusive() {
        for mode in HeroBackgroundMode.allCases {
            let settings = HeroBackgroundSettings(mode: mode)
            XCTAssertFalse(
                settings.trailerAutoplayEnabled && settings.themeMusicEnabled,
                "Trailer and theme music may never be enabled together"
            )
        }
    }

    func testLenientDecodeFallsBackForUnknownModeAndMissingMute() throws {
        let data = Data(#"{"mode":"future-mode"}"#.utf8)
        let decoded = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(decoded, .default)
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

        let loaded = HeroBackgroundSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.mode, .themeMusic)
    }

    func testStorePreservesEnabledSilentThemeMusicAsThemeMode() {
        let suite = "HeroBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ThemeMusicSettings(isEnabled: true, volume: .off)
        defaults.set(
            try! JSONEncoder().encode(legacy),
            forKey: "com.plozz.themeMusicSettings"
        )

        XCTAssertEqual(
            HeroBackgroundSettingsStore(defaults: defaults).load().mode,
            .themeMusic
        )
    }
}
