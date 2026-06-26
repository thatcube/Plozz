import XCTest
@testable import CoreModels

/// Tests for the persisted music-availability map that lets the Music tab paint
/// on the first frame of a relaunch without a network probe.
final class MusicAvailabilityStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MusicAvailabilityStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRoundTripsRawLibraryMap() {
        let store = MusicAvailabilityStore(defaults: makeDefaults())
        let map = ["jellyfin": ["v1", "v2"], "plex": ["7"]]
        store.save(map)
        XCTAssertEqual(store.load(), map)
    }

    func testEmptyStartsEmptyAndSavingEmptyClears() {
        let store = MusicAvailabilityStore(defaults: makeDefaults())
        XCTAssertTrue(store.load().isEmpty)
        store.save(["plex": ["1"]])
        XCTAssertFalse(store.load().isEmpty)
        store.save([:])
        XCTAssertTrue(store.load().isEmpty, "saving an empty map clears the entry")
    }

    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = MusicAvailabilityStore(defaults: defaults, namespace: nil)
        let other = MusicAvailabilityStore(defaults: defaults, namespace: "profile-b")
        primary.save(["plex": ["1"]])
        XCTAssertEqual(primary.load(), ["plex": ["1"]])
        XCTAssertTrue(other.load().isEmpty, "a second profile has its own independent availability")
    }

    func testEphemeralStoreRoundTrips() {
        let store = EphemeralMusicAvailabilityStore(seed: ["a": ["1"]])
        XCTAssertEqual(store.load(), ["a": ["1"]])
        store.save(["b": ["2", "3"]])
        XCTAssertEqual(store.load(), ["b": ["2", "3"]])
    }
}
