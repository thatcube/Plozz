import XCTest
@testable import CoreModels

final class CardStyleSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CardStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsFramedWhenEmpty() {
        let store = CardStyleSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .framed)
        XCTAssertEqual(CardStyle.default, .framed)
    }

    func testRoundTripForEveryStyle() {
        let defaults = makeDefaults()
        let store = CardStyleSettingsStore(defaults: defaults)
        for style in CardStyle.allCases {
            store.save(style)
            XCTAssertEqual(store.load(), style)
        }
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-style", forKey: "com.plozz.cardStyle")
        XCTAssertEqual(CardStyleSettingsStore(defaults: defaults).load(), .default)
    }

    /// The primary profile (`namespace == nil`) keeps the legacy un-suffixed key.
    func testPrimaryProfileUsesLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(CardStyle.borderless.rawValue, forKey: "com.plozz.cardStyle")
        let store = CardStyleSettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), .borderless)
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = CardStyleSettingsStore(defaults: defaults, namespace: nil)
        let alice = CardStyleSettingsStore(defaults: defaults, namespace: "alice")
        let bob = CardStyleSettingsStore(defaults: defaults, namespace: "bob")

        primary.save(.framed)
        alice.save(.borderless)
        bob.save(.framed)

        XCTAssertEqual(primary.load(), .framed)
        XCTAssertEqual(alice.load(), .borderless)
        XCTAssertEqual(bob.load(), .framed)

        // The namespaced profile uses the suffixed key, leaving the legacy key alone.
        XCTAssertEqual(defaults.string(forKey: "com.plozz.cardStyle.alice"), CardStyle.borderless.rawValue)
        XCTAssertEqual(defaults.string(forKey: "com.plozz.cardStyle"), CardStyle.framed.rawValue)
    }

    @MainActor
    func testModelPersistsOnChange() {
        let defaults = makeDefaults()
        let model = CardStyleSettingsModel(store: CardStyleSettingsStore(defaults: defaults))
        model.style = .borderless
        XCTAssertEqual(CardStyleSettingsStore(defaults: defaults).load(), .borderless)
    }
}
