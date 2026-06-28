import XCTest
@testable import CoreModels

final class UIDensitySettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "UIDensitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsStandardWhenEmpty() {
        let store = UIDensitySettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .standard)
    }

    func testRoundTripForEveryDensity() {
        let defaults = makeDefaults()
        let store = UIDensitySettingsStore(defaults: defaults)
        for density in UIDensity.allCases {
            store.save(density)
            XCTAssertEqual(store.load(), density)
        }
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-density", forKey: "com.plozz.uiDensity")
        XCTAssertEqual(UIDensitySettingsStore(defaults: defaults).load(), .default)
    }

    /// The primary profile (`namespace == nil`) keeps the legacy un-suffixed key.
    func testPrimaryProfileUsesLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(UIDensity.spacious.rawValue, forKey: "com.plozz.uiDensity")
        let store = UIDensitySettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), .spacious)
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = UIDensitySettingsStore(defaults: defaults, namespace: nil)
        let alice = UIDensitySettingsStore(defaults: defaults, namespace: "alice")
        let bob = UIDensitySettingsStore(defaults: defaults, namespace: "bob")

        primary.save(.compact)
        alice.save(.extraLarge)
        bob.save(.spacious)

        XCTAssertEqual(primary.load(), .compact)
        XCTAssertEqual(alice.load(), .extraLarge)
        XCTAssertEqual(bob.load(), .spacious)

        // The namespaced profile uses the suffixed key, leaving the legacy key alone.
        XCTAssertEqual(defaults.string(forKey: "com.plozz.uiDensity.alice"), UIDensity.extraLarge.rawValue)
        XCTAssertEqual(defaults.string(forKey: "com.plozz.uiDensity"), UIDensity.compact.rawValue)
    }

    @MainActor
    func testModelPersistsOnChange() {
        let defaults = makeDefaults()
        let model = UIDensitySettingsModel(store: UIDensitySettingsStore(defaults: defaults))
        model.density = .extraLarge
        XCTAssertEqual(UIDensitySettingsStore(defaults: defaults).load(), .extraLarge)
    }

    func testScaleAndColumnsRampMonotonically() {
        // Higher density → larger scale and fewer poster columns. The settings
        // ladder relies on this ordering being monotonic.
        let order: [UIDensity] = [.extraCompact, .compact, .standard, .spacious, .extraLarge]
        for (lhs, rhs) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(lhs.scale, rhs.scale, "\(lhs) should scale smaller than \(rhs)")
            XCTAssertGreaterThan(lhs.posterGridColumns, rhs.posterGridColumns, "\(lhs) should have more columns than \(rhs)")
        }
        XCTAssertEqual(UIDensity.standard.scale, 1.0)
    }
}
