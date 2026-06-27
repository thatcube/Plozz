import XCTest
@testable import FeatureHome

/// Locks down `HomeLayoutStore` persistence: round-trip, per-profile scoping,
/// and defensive filtering of unknown row kinds from older persisted values.
final class HomeLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HomeLayoutStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsEmptyWhenNothingPersisted() {
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSaveLoadRoundTripPreservesOrder() {
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        let layout: [HomeRowKind] = [.continueWatching, .recentlyAdded, .libraries]
        store.save(layout)
        XCTAssertEqual(store.load(), layout)
    }

    func testNamespacesAreIsolated() {
        let primary = HomeLayoutStore(defaults: defaults, namespace: nil)
        let other = HomeLayoutStore(defaults: defaults, namespace: "profile-2")
        primary.save([.continueWatching])
        other.save([.watchlist, .libraries])
        XCTAssertEqual(primary.load(), [.continueWatching])
        XCTAssertEqual(other.load(), [.watchlist, .libraries])
    }

    func testUnknownRawValuesAreFilteredOut() {
        // Simulate an older build that persisted a now-removed row kind.
        defaults.set(["continueWatching", "bogus", "libraries"], forKey: "com.plozz.homeLayout")
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), [.continueWatching, .libraries])
    }

    func testInMemoryStoreRoundTrips() {
        let store = InMemoryHomeLayoutStore([.libraries])
        XCTAssertEqual(store.load(), [.libraries])
        store.save([.continueWatching, .watchlist])
        XCTAssertEqual(store.load(), [.continueWatching, .watchlist])
    }
}
