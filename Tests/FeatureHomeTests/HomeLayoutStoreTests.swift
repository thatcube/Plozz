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

    func testSaveLoadRoundTripPreservesOrderAndCounts() {
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        let layout: [HomeRowLayout] = [
            HomeRowLayout(kind: .continueWatching, count: 3),
            HomeRowLayout(kind: .recentlyAdded, count: 24),
            HomeRowLayout(kind: .libraries, count: 6),
        ]
        store.save(layout)
        XCTAssertEqual(store.load(), layout)
    }

    func testNamespacesAreIsolated() {
        let primary = HomeLayoutStore(defaults: defaults, namespace: nil)
        let other = HomeLayoutStore(defaults: defaults, namespace: "profile-2")
        primary.save([HomeRowLayout(kind: .continueWatching, count: 2)])
        other.save([HomeRowLayout(kind: .watchlist, count: 8), HomeRowLayout(kind: .libraries, count: 4)])
        XCTAssertEqual(primary.load(), [HomeRowLayout(kind: .continueWatching, count: 2)])
        XCTAssertEqual(other.load(), [HomeRowLayout(kind: .watchlist, count: 8), HomeRowLayout(kind: .libraries, count: 4)])
    }

    func testUnknownRawValuesAreFilteredOut() {
        // Simulate a persisted value that includes a now-removed row kind.
        let key = "com.plozz.homeLayout.v2"
        let json = #"[{"kind":"continueWatching","count":3},{"kind":"bogus","count":9},{"kind":"libraries","count":5}]"#
        defaults.set(Data(json.utf8), forKey: key)
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), [
            HomeRowLayout(kind: .continueWatching, count: 3),
            HomeRowLayout(kind: .libraries, count: 5),
        ])
    }

    func testPreV2ArrayValueIsIgnored() {
        // A legacy bare `[String]` value under the old key must not crash or
        // corrupt the v2 read; the store simply falls back to "nothing persisted".
        defaults.set(["continueWatching", "libraries"], forKey: "com.plozz.homeLayout")
        let store = HomeLayoutStore(defaults: defaults, namespace: nil)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testInMemoryStoreRoundTrips() {
        let store = InMemoryHomeLayoutStore([HomeRowLayout(kind: .libraries, count: 4)])
        XCTAssertEqual(store.load(), [HomeRowLayout(kind: .libraries, count: 4)])
        store.save([HomeRowLayout(kind: .continueWatching, count: 1), HomeRowLayout(kind: .watchlist, count: 12)])
        XCTAssertEqual(store.load(), [HomeRowLayout(kind: .continueWatching, count: 1), HomeRowLayout(kind: .watchlist, count: 12)])
    }
}
