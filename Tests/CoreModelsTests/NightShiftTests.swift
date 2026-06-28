import XCTest
@testable import CoreModels

final class NightShiftSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NightShiftSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsWhenEmpty() {
        let store = NightShiftSettingsStore(defaults: makeDefaults())
        let loaded = store.load()
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.warmth, .warmer)
        XCTAssertEqual(loaded.dimness, .medium)
        XCTAssertEqual(loaded.scheduleMode, .solar)
        XCTAssertEqual(loaded.manualOnMinutes, 20 * 60)
        XCTAssertEqual(loaded.manualOffMinutes, 6 * 60)
        XCTAssertEqual(loaded.fadeMinutes, 90)
        XCTAssertFalse(loaded.regionID.isEmpty)
    }

    func testRoundTrip() {
        let defaults = makeDefaults()
        let store = NightShiftSettingsStore(defaults: defaults)
        let settings = NightShiftSettings(
            isEnabled: true,
            regionID: "America/New_York",
            warmth: .onFire,
            dimness: .strong,
            scheduleMode: .manual,
            manualOnMinutes: 19 * 60 + 30,
            manualOffMinutes: 7 * 60,
            fadeMinutes: 45
        )
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        // A fresh store over the same defaults must read the same value.
        XCTAssertEqual(NightShiftSettingsStore(defaults: defaults).load(), settings)
    }

    func testNamespaceIsolation() {
        let defaults = makeDefaults()
        let primary = NightShiftSettingsStore(defaults: defaults, namespace: nil)
        let kid = NightShiftSettingsStore(defaults: defaults, namespace: "profile-kid")

        var a = NightShiftSettings.default
        a.isEnabled = true
        a.warmth = .light
        primary.save(a)

        var b = NightShiftSettings.default
        b.isEnabled = false
        b.warmth = .onFire
        kid.save(b)

        XCTAssertEqual(primary.load().warmth, .light)
        XCTAssertTrue(primary.load().isEnabled)
        XCTAssertEqual(kid.load().warmth, .onFire)
        XCTAssertFalse(kid.load().isEnabled)
    }
}

final class NightShiftRegionTests: XCTestCase {
    func testCatalogLookup() {
        XCTAssertFalse(NightShiftRegion.catalog.isEmpty)
        XCTAssertEqual(NightShiftRegion.region(id: "Europe/London")?.name, "London")
        XCTAssertNil(NightShiftRegion.region(id: "Not/AReal_Zone"))
    }

    func testSortedCatalogIsAlphabetical() {
        let names = NightShiftRegion.sortedCatalog.map(\.name)
        XCTAssertEqual(names, names.sorted())
    }

    func testGuessAlwaysResolves() {
        // Whatever the host zone is, we must land on a real catalog entry.
        let guess = NightShiftRegion.guessFromCurrentTimeZone()
        XCTAssertTrue(NightShiftRegion.catalog.contains(guess))
    }
}

final class SolarTimeTests: XCTestCase {
    func testSunriseBeforeSunsetForLondon() {
        let tz = TimeZone(identifier: "Europe/London")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let june = cal.date(from: DateComponents(year: 2025, month: 6, day: 21))!
        let times = SolarTime.sunriseSunset(latitude: 51.51, longitude: -0.13, on: june, timeZone: tz)
        let unwrapped = try? XCTUnwrap(times)
        XCTAssertNotNil(unwrapped)
        if let t = unwrapped {
            XCTAssertLessThan(t.sunrise, t.sunset)
        }
    }

    func testPolarNightReturnsNil() {
        // Far north in deep winter: the sun never rises → no transition.
        let tz = TimeZone(identifier: "America/Anchorage")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dec = cal.date(from: DateComponents(year: 2025, month: 12, day: 21))!
        let times = SolarTime.sunriseSunset(latitude: 78.0, longitude: -150.0, on: dec, timeZone: tz)
        XCTAssertNil(times)
    }
}

@MainActor
final class NightShiftModelTests: XCTestCase {
    private func makeModel(_ settings: NightShiftSettings) -> NightShiftSettingsModel {
        let suite = "NightShiftModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = NightShiftSettingsModel(store: NightShiftSettingsStore(defaults: defaults))
        model.settings = settings
        return model
    }

    private func todayAt(hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    func testDisabledIsIdentity() {
        var s = NightShiftSettings.default
        s.isEnabled = false
        let model = makeModel(s)
        XCTAssertEqual(model.currentIntensity, 0)
        XCTAssertEqual(model.channelScalars, .identity)
        XCTAssertFalse(model.isActiveNow)
    }

    func testManualWindowWrapsMidnight() {
        var s = NightShiftSettings.default
        s.isEnabled = true
        s.scheduleMode = .manual
        s.manualOnMinutes = 20 * 60   // 20:00
        s.manualOffMinutes = 6 * 60   // 06:00 next day
        s.fadeMinutes = 60
        let model = makeModel(s)

        // 03:00 is deep inside the overnight window → full strength.
        model.previewDate = todayAt(hour: 3)
        XCTAssertEqual(model.currentIntensity, 1, accuracy: 0.0001)

        // Noon is outside the window → off.
        model.previewDate = todayAt(hour: 12)
        XCTAssertEqual(model.currentIntensity, 0, accuracy: 0.0001)
    }

    func testAlwaysOnIsFullStrengthRegardlessOfTime() {
        var s = NightShiftSettings.default
        s.isEnabled = true
        s.scheduleMode = .alwaysOn
        let model = makeModel(s)

        // Always-on ignores the clock: full strength at noon and at midnight.
        model.previewDate = todayAt(hour: 12)
        XCTAssertEqual(model.currentIntensity, 1, accuracy: 0.0001)
        model.previewDate = todayAt(hour: 0)
        XCTAssertEqual(model.currentIntensity, 1, accuracy: 0.0001)
        XCTAssertTrue(model.isActiveNow)
    }

    func testChannelScalarsWarmAndDimAtFullNight() {
        var s = NightShiftSettings.default
        s.isEnabled = true
        s.scheduleMode = .manual
        s.manualOnMinutes = 20 * 60
        s.manualOffMinutes = 6 * 60
        s.fadeMinutes = 60
        s.dimness = .medium   // peak 0.55
        s.warmth = .warmer    // peak 0.80, greenKill 0.65
        let model = makeModel(s)
        model.previewDate = todayAt(hour: 3) // intensity == 1

        let c = model.channelScalars
        XCTAssertEqual(c.red, 0.45, accuracy: 0.0001)        // 1 - dim
        // Warm tint loses green and (more) blue, so red > green > blue.
        XCTAssertLessThan(c.green, c.red)
        XCTAssertLessThan(c.blue, c.green)
        XCTAssertTrue(model.isActiveNow)
    }

    func testFadeLabel() {
        XCTAssertEqual(NightShiftSettingsModel.fadeLabel(minutes: 45), "45m")
        XCTAssertEqual(NightShiftSettingsModel.fadeLabel(minutes: 60), "1h")
        XCTAssertEqual(NightShiftSettingsModel.fadeLabel(minutes: 90), "1.5h")
    }

    func testScheduleSummaryReflectsState() {
        var s = NightShiftSettings.default
        s.isEnabled = false
        s.scheduleMode = .manual
        let model = makeModel(s)
        XCTAssertTrue(model.scheduleSummary().hasPrefix("Off."))

        model.settings.isEnabled = true
        // Active or idle, an enabled manual schedule mentions "Manual".
        XCTAssertTrue(model.scheduleSummary().contains("Manual"))
    }
}
