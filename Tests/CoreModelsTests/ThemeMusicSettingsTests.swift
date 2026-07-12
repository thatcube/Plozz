import XCTest
@testable import CoreModels

final class ThemeMusicSettingsTests: XCTestCase {
    func testThemeMusicCarriesCredentialFreeSource() throws {
        let source = try SecretFreeURLSource(
            url: URL(string: "https://themes.example/title.mp3")!
        )
        let theme = ThemeMusic(
            itemID: "title",
            playbackSource: .publicURL(source),
            title: "Main Theme"
        )

        XCTAssertEqual(
            theme.playbackSource.publicURL,
            URL(string: "https://themes.example/title.mp3")
        )
        XCTAssertEqual(theme.title, "Main Theme")
    }

    func testDefaultIsOptInOff() {
        let settings = ThemeMusicSettings.default
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.shouldPlay)
    }

    func testShouldPlayRequiresEnabledAndAudibleVolume() {
        XCTAssertFalse(ThemeMusicSettings(isEnabled: false, volume: .high).shouldPlay)
        XCTAssertFalse(ThemeMusicSettings(isEnabled: true, volume: .off).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .low).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .medium).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .high).shouldPlay)
    }

    func testVolumeGainIsSoftAndMonotonic() {
        XCTAssertEqual(ThemeMusicVolume.off.gain, 0)
        XCTAssertLessThan(ThemeMusicVolume.low.gain, ThemeMusicVolume.medium.gain)
        XCTAssertLessThan(ThemeMusicVolume.medium.gain, ThemeMusicVolume.high.gain)
        XCTAssertLessThanOrEqual(ThemeMusicVolume.high.gain, 0.7)
    }

    func testCodableRoundTrip() throws {
        let settings = ThemeMusicSettings(
            isEnabled: true,
            volume: .medium
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(
            try JSONDecoder().decode(ThemeMusicSettings.self, from: data),
            settings
        )
    }

    func testLenientDecodeUsesDefaultsForMissingAndUnknownFields() throws {
        let missing = try JSONDecoder().decode(
            ThemeMusicSettings.self,
            from: Data(#"{"isEnabled":true,"loops":true}"#.utf8)
        )
        XCTAssertTrue(missing.isEnabled)
        XCTAssertEqual(missing.volume, .low)

        let unknown = try JSONDecoder().decode(
            ThemeMusicSettings.self,
            from: Data(#"{"isEnabled":true,"volume":"deafening"}"#.utf8)
        )
        XCTAssertEqual(unknown.volume, .low)
    }

    func testStoreRoundTripAndProfileIsolation() {
        let suite = "ThemeMusicSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let primary = ThemeMusicSettingsStore(defaults: defaults)
        let second = ThemeMusicSettingsStore(defaults: defaults, namespace: "profile-2")
        let saved = ThemeMusicSettings(
            isEnabled: true,
            volume: .high
        )

        primary.save(saved)
        XCTAssertEqual(primary.load(), saved)
        XCTAssertEqual(second.load(), .default)
    }

    @MainActor
    func testModelPersistsChanges() {
        let suite = "ThemeMusicSettingsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeMusicSettingsStore(defaults: defaults)
        let model = ThemeMusicSettingsModel(store: store)
        model.settings.isEnabled = true
        model.settings.volume = .medium

        XCTAssertTrue(store.load().isEnabled)
        XCTAssertEqual(store.load().volume, .medium)
    }
}
