import XCTest
@testable import CoreModels

/// Locks down `HeroSettings` value semantics (clamping, de-dup, lenient decode)
/// and `HeroSettingsStore` persistence (round-trip + per-profile scoping).
final class HeroSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HeroSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultIsActiveWithAllSources() {
        let d = HeroSettings.default
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.sources, HeroSourceKind.allCases)
        XCTAssertTrue(d.hideWatched)
    }

    func testMaxItemsIsClamped() {
        let low = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 0, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        XCTAssertEqual(low.maxItems, HeroSettings.maxItemsRange.lowerBound)
        let high = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 999, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        XCTAssertEqual(high.maxItems, HeroSettings.maxItemsRange.upperBound)
    }

    func testAutoAdvanceSecondsIsClamped() {
        let s = HeroSettings(isEnabled: true, sources: [.watchlist], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 1)
        XCTAssertEqual(s.autoAdvanceSeconds, HeroSettings.autoAdvanceRange.lowerBound)
    }

    func testDuplicateSourcesAreCollapsedPreservingOrder() {
        let s = HeroSettings(isEnabled: true, sources: [.watchlist, .continueWatching, .watchlist], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertEqual(s.sources, [.watchlist, .continueWatching])
    }

    func testEmptySourcesIsNotActive() {
        let s = HeroSettings(isEnabled: true, sources: [], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertFalse(s.isActive)
    }

    func testDisabledIsNotActive() {
        let s = HeroSettings(isEnabled: false, sources: [.featured], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertFalse(s.isActive)
    }

    func testStoreRoundTrip() {
        let store = HeroSettingsStore(defaults: defaults, namespace: nil)
        let settings = HeroSettings(isEnabled: true, sources: [.featured, .randomFromLibrary], maxItems: 6, trailersEnabled: true, hideWatched: false, randomLibraryKeys: ["a:1", "a:2"], autoAdvance: false, autoAdvanceSeconds: 20)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testStoreDefaultsWhenEmpty() {
        let store = HeroSettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), .default)
    }

    func testNamespacesAreIsolated() {
        let primary = HeroSettingsStore(defaults: defaults, namespace: nil)
        let other = HeroSettingsStore(defaults: defaults, namespace: "profile-2")
        let a = HeroSettings(isEnabled: true, sources: [.watchlist], maxItems: 3, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        let b = HeroSettings(isEnabled: false, sources: [.featured], maxItems: 9, trailersEnabled: true, randomLibraryKeys: ["x:1"], autoAdvance: false, autoAdvanceSeconds: 30)
        primary.save(a)
        other.save(b)
        XCTAssertEqual(primary.load(), a)
        XCTAssertEqual(other.load(), b)
    }

    func testLenientDecodeFillsMissingFieldsWithDefaults() throws {
        // A partial blob (as an older app version might have written) must decode
        // with the absent fields at their defaults, not fail the whole decode.
        let json = #"{"isEnabled":false,"maxItems":4}"#
        let decoded = try JSONDecoder().decode(HeroSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.maxItems, 4)
        XCTAssertEqual(decoded.sources, HeroSettings.default.sources)
        XCTAssertEqual(decoded.autoAdvanceSeconds, HeroSettings.default.autoAdvanceSeconds)
        XCTAssertTrue(decoded.hideWatched)
    }

    func testInMemoryStoreRoundTrips() {
        let store = InMemoryHeroSettingsStore()
        XCTAssertEqual(store.load(), .default)
        let s = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 2, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 8)
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
