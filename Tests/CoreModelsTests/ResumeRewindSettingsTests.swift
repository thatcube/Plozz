import XCTest
@testable import CoreModels

/// Covers the per-profile "resume rewind" setting: the `ResumeRewindInterval`
/// enum + its `applied(to:)` maths, `PlaybackSettings` defaults, round-tripping,
/// upgrade-safe decoding when the field is absent from older payloads, and
/// per-profile independence.
final class ResumeRewindSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ResumeRewindSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // MARK: - ResumeRewindInterval enum

    func testAllCasesHaveDistinctRawValues() {
        let raws = ResumeRewindInterval.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "Every case must have a unique raw value")
    }

    func testSecondsMatchesRawValue() {
        for interval in ResumeRewindInterval.allCases {
            XCTAssertEqual(interval.seconds, TimeInterval(interval.rawValue))
        }
    }

    func testOffIsZeroSeconds() {
        XCTAssertEqual(ResumeRewindInterval.off.seconds, 0)
        XCTAssertEqual(ResumeRewindInterval.off.title, "Off")
    }

    // MARK: - applied(to:) maths

    func testAppliedRewindsFromResumePoint() {
        XCTAssertEqual(ResumeRewindInterval.five.applied(to: 100), 95)
        XCTAssertEqual(ResumeRewindInterval.ten.applied(to: 100), 90)
        XCTAssertEqual(ResumeRewindInterval.thirty.applied(to: 100), 70)
    }

    func testOffNeverRewinds() {
        XCTAssertEqual(ResumeRewindInterval.off.applied(to: 100), 100)
        XCTAssertEqual(ResumeRewindInterval.off.applied(to: 0), 0)
    }

    func testStartOverPositionIsNeverRewound() {
        // A non-positive base ("start over" / fresh start) is returned unchanged so
        // the nudge never pushes below the beginning.
        XCTAssertEqual(ResumeRewindInterval.five.applied(to: 0), 0)
        XCTAssertEqual(ResumeRewindInterval.ten.applied(to: -5), -5)
    }

    func testResumeSmallerThanRewindClampsToZero() {
        // A resume point closer to the start than the rewind simply starts over.
        XCTAssertEqual(ResumeRewindInterval.ten.applied(to: 3), 0)
        XCTAssertEqual(ResumeRewindInterval.five.applied(to: 5), 0)
    }

    // MARK: - PlaybackSettings defaults

    func testDefaultResumeRewindIsFive() {
        XCTAssertEqual(PlaybackSettings.default.resumeRewindInterval, .five)
    }

    // MARK: - Round-trip persistence

    func testRoundTripsResumeRewind() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.resumeRewindInterval = .thirty
        store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.resumeRewindInterval, .thirty)
        // Unrelated fields stay intact.
        XCTAssertEqual(loaded.skipForwardInterval, .ten)
        XCTAssertTrue(loaded.syncWatchAcrossServers)
    }

    func testCanBeTurnedOff() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.resumeRewindInterval = .off
        store.save(settings)

        XCTAssertEqual(store.load().resumeRewindInterval, .off)
    }

    // MARK: - Upgrade-safe decoding

    func testLegacyPayloadWithoutResumeRewindDefaultsToFive() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(
            withJSONObject: ["skipIntros": "on", "syncWatchAcrossServers": true]
        )
        defaults.set(legacy, forKey: key)

        let store = PlaybackSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded.skipIntros, .on, "Existing field preserved")
        XCTAssertEqual(loaded.resumeRewindInterval, .five,
                       "Missing field must default to 5s — resume rewind is on for upgrades too")
    }

    // MARK: - Per-profile independence

    func testPerProfileResumeRewindIsIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest-profile")

        var guestSettings = PlaybackSettings.default
        guestSettings.resumeRewindInterval = .off
        guest.save(guestSettings)

        // Guest opted out.
        XCTAssertEqual(guest.load().resumeRewindInterval, .off)
        // Primary is unaffected (still the default).
        XCTAssertEqual(primary.load().resumeRewindInterval, .five)
    }

    // MARK: - Codable round-trip (direct)

    func testCodableRoundTrip() throws {
        var original = PlaybackSettings.default
        original.resumeRewindInterval = .fifteen

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
