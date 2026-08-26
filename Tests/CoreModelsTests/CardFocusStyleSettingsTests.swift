import XCTest
@testable import CoreModels

final class CardFocusStyleSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CardFocusStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// New installs get the native treatment without visiting Settings.
    func testDefaultIsHighlightWhenEmpty() {
        let store = CardFocusStyleSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .highlight)
        XCTAssertEqual(CardFocusStyle.default, .highlight)
    }

    func testOnlyTheOutlinedStyleDrawsAnOutline() {
        XCTAssertTrue(CardFocusStyle.outlined.drawsFocusOutline)
        XCTAssertFalse(CardFocusStyle.highlight.drawsFocusOutline)
    }

    func testRoundTripForEveryStyle() {
        let defaults = makeDefaults()
        let store = CardFocusStyleSettingsStore(defaults: defaults)
        for style in CardFocusStyle.allCases {
            store.save(style)
            XCTAssertEqual(store.load(), style)
        }
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-style", forKey: "com.plozz.cardFocusStyle")
        XCTAssertEqual(CardFocusStyleSettingsStore(defaults: defaults).load(), .default)
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = CardFocusStyleSettingsStore(defaults: defaults, namespace: nil)
        let alice = CardFocusStyleSettingsStore(defaults: defaults, namespace: "alice")

        primary.save(.highlight)
        alice.save(.outlined)

        XCTAssertEqual(primary.load(), .highlight)
        XCTAssertEqual(alice.load(), .outlined)
        XCTAssertEqual(
            defaults.string(forKey: "com.plozz.cardFocusStyle.alice"),
            CardFocusStyle.outlined.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: "com.plozz.cardFocusStyle"),
            CardFocusStyle.highlight.rawValue
        )
    }

    /// The focus style rides on the shared card-presentation model, so editing it
    /// there is what has to persist.
    @MainActor
    func testCardStyleModelPersistsFocusStyleOnChange() {
        let defaults = makeDefaults()
        let model = CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults)
        )
        XCTAssertEqual(model.focusStyle, .highlight)
        model.focusStyle = .outlined
        XCTAssertEqual(CardFocusStyleSettingsStore(defaults: defaults).load(), .outlined)
        // The two preferences are stored separately and don't disturb each other.
        XCTAssertEqual(CardStyleSettingsStore(defaults: defaults).load(), model.style)
    }
}
