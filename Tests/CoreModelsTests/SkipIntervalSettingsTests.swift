import XCTest
@testable import CoreModels

/// Covers the per-profile skip-interval settings: defaults, round-tripping,
/// upgrade-safe decoding when the fields are absent from older payloads, and
/// per-profile independence.
final class SkipIntervalSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SkipIntervalSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // MARK: - SkipInterval enum

    func testAllCasesHaveDistinctRawValues() {
        let raws = SkipInterval.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "Every case must have a unique raw value")
    }

    func testSecondsMatchesRawValue() {
        for interval in SkipInterval.allCases {
            XCTAssertEqual(interval.seconds, TimeInterval(interval.rawValue))
        }
    }

    func testSFSymbolNames() {
        XCTAssertEqual(SkipInterval.ten.forwardSymbol, "goforward.10")
        XCTAssertEqual(SkipInterval.ten.backwardSymbol, "gobackward.10")
        XCTAssertEqual(SkipInterval.thirty.forwardSymbol, "goforward.30")
        XCTAssertEqual(SkipInterval.five.backwardSymbol, "gobackward.5")
    }

    // MARK: - PlaybackSettings defaults

    func testDefaultIntervalIsTen() {
        XCTAssertEqual(PlaybackSettings.default.skipForwardInterval, .ten)
        XCTAssertEqual(PlaybackSettings.default.skipBackwardInterval, .ten)
    }

    // MARK: - Round-trip persistence

    func testRoundTripsSkipIntervals() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.skipForwardInterval = .thirty
        settings.skipBackwardInterval = .five
        store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.skipForwardInterval, .thirty)
        XCTAssertEqual(loaded.skipBackwardInterval, .five)
        // Unrelated fields stay intact
        XCTAssertEqual(loaded.skipIntros, .off)
        XCTAssertTrue(loaded.syncWatchAcrossServers)
    }

    // MARK: - Upgrade-safe decoding

    func testLegacyPayloadWithoutIntervalsDecodesToTen() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(
            withJSONObject: ["skipIntros": "on", "syncWatchAcrossServers": true]
        )
        defaults.set(legacy, forKey: key)

        let store = PlaybackSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded.skipIntros, .on, "Existing field preserved")
        XCTAssertEqual(loaded.skipForwardInterval, .ten,
                       "Missing field must default to 10s for upgrade safety")
        XCTAssertEqual(loaded.skipBackwardInterval, .ten,
                       "Missing field must default to 10s for upgrade safety")
    }

    // MARK: - Per-profile independence

    func testPerProfileIntervalsAreIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest-profile")

        var guestSettings = PlaybackSettings.default
        guestSettings.skipForwardInterval = .sixty
        guestSettings.skipBackwardInterval = .fifteen
        guest.save(guestSettings)

        // Guest has custom intervals
        let loadedGuest = guest.load()
        XCTAssertEqual(loadedGuest.skipForwardInterval, .sixty)
        XCTAssertEqual(loadedGuest.skipBackwardInterval, .fifteen)

        // Primary is unaffected (still defaults)
        let loadedPrimary = primary.load()
        XCTAssertEqual(loadedPrimary.skipForwardInterval, .ten)
        XCTAssertEqual(loadedPrimary.skipBackwardInterval, .ten)
    }

    // MARK: - Codable round-trip (direct)

    func testCodableRoundTrip() throws {
        var original = PlaybackSettings.default
        original.skipForwardInterval = .fifteen
        original.skipBackwardInterval = .sixty
        original.skipIntros = .autoDelay

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
