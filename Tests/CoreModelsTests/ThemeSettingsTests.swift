import XCTest
@testable import CoreModels

final class ThemeSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ThemeSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsDarkWhenEmpty() {
        let store = ThemeSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .dark)
        XCTAssertEqual(AppTheme.default, .dark)
    }

    func testRoundTripForEveryTheme() {
        let defaults = makeDefaults()
        let store = ThemeSettingsStore(defaults: defaults)
        for theme in AppTheme.allCases {
            store.save(theme)
            XCTAssertEqual(store.load(), theme, "\(theme) did not round-trip")
            // A fresh store over the same defaults must read the same value.
            XCTAssertEqual(ThemeSettingsStore(defaults: defaults).load(), theme)
        }
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-theme", forKey: "com.plozz.appTheme")
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults).load(), .default)
    }

    @MainActor
    func testModelPersistsOnChange() {
        let defaults = makeDefaults()
        let model = ThemeSettingsModel(store: ThemeSettingsStore(defaults: defaults))
        XCTAssertEqual(model.theme, .dark)
        model.theme = .oled
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults).load(), .oled)
    }

    func testCodableRoundTrip() throws {
        for theme in AppTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(AppTheme.self, from: data), theme)
        }
    }

    func testPickerOrderCoversEveryThemeCase() {
        // The pickers iterate `pickerOrder`, not `allCases`, so a new case added to
        // the enum but forgotten in `pickerOrder` would be silently unselectable.
        XCTAssertEqual(Set(AppTheme.pickerOrder), Set(AppTheme.allCases))
        XCTAssertEqual(AppTheme.pickerOrder.count, AppTheme.allCases.count)
        XCTAssertEqual(Set(MusicPlayerAppearance.pickerOrder), Set(MusicPlayerAppearance.allCases))
        XCTAssertEqual(MusicPlayerAppearance.pickerOrder.count, MusicPlayerAppearance.allCases.count)
    }
}

#if canImport(SwiftUI)
import SwiftUI
import CoreUI

final class ThemePaletteResolutionTests: XCTestCase {
    func testEveryThemeResolvesAPalette() {
        for theme in AppTheme.allCases {
            let dark = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            let light = ThemePalette.palette(for: theme, systemColorScheme: .light)
            // `.system` follows the device scheme; the rest ignore it.
            if theme == .system {
                XCTAssertEqual(dark, .dark)
                XCTAssertEqual(light, .light)
            } else {
                XCTAssertEqual(dark, light, "\(theme) should not depend on the system scheme")
            }
        }
    }

    func testOLEDHasNoGlowOthersAreThemed() {
        XCTAssertNil(ThemePalette.oled.topGlow)
        XCTAssertNotNil(ThemePalette.dark.topGlow)
        XCTAssertNotNil(ThemePalette.light.topGlow)
    }
}
#endif
