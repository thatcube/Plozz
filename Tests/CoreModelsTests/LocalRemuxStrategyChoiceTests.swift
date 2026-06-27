import XCTest
@testable import CoreModels

/// Covers the dynamic-choice registry that lets engine modules contribute a
/// strategy at launch and have it recognised by display-name resolution and by
/// `PlaybackPreferencesStore` persistence.
final class LocalRemuxStrategyChoiceTests: XCTestCase {
    private static let testChoice = LocalRemuxStrategyChoice(
        id: "test.cue-driven-registry",
        displayName: "Cue Driven (test)",
        detail: "Registered by LocalRemuxStrategyChoiceTests."
    )

    override func setUp() {
        super.setUp()
        LocalRemuxStrategyChoice.registerDynamic(Self.testChoice)
    }

    func testBuiltInChoicesAlwaysPresent() {
        let ids = LocalRemuxStrategyChoice.allChoices.map(\.id)
        XCTAssertTrue(ids.contains(LocalRemuxStrategyChoice.disabledID))
        XCTAssertTrue(ids.contains(LocalRemuxStrategyChoice.referenceServerRemuxID))
        // Built-ins come first, in declared order.
        XCTAssertEqual(LocalRemuxStrategyChoice.allChoices.first?.id, LocalRemuxStrategyChoice.disabledID)
    }

    func testDynamicChoiceAppearsInAllChoices() {
        XCTAssertTrue(LocalRemuxStrategyChoice.dynamicChoices.contains { $0.id == Self.testChoice.id })
        XCTAssertTrue(LocalRemuxStrategyChoice.allChoices.contains { $0.id == Self.testChoice.id })
    }

    func testChoiceForResolvesDynamicID() {
        let resolved = LocalRemuxStrategyChoice.choice(for: Self.testChoice.id)
        XCTAssertEqual(resolved.id, Self.testChoice.id)
        XCTAssertEqual(resolved.displayName, "Cue Driven (test)")
    }

    func testChoiceForUnknownIDFallsBackToDisabled() {
        XCTAssertEqual(LocalRemuxStrategyChoice.choice(for: "no.such.id").id, LocalRemuxStrategyChoice.disabledID)
    }

    func testRegisteringSameIDReplacesMetadataIdempotently() {
        let before = LocalRemuxStrategyChoice.allChoices.count
        LocalRemuxStrategyChoice.registerDynamic(
            LocalRemuxStrategyChoice(id: Self.testChoice.id, displayName: "Renamed", detail: "v2")
        )
        let after = LocalRemuxStrategyChoice.allChoices.count
        XCTAssertEqual(before, after, "Re-registering an id must not duplicate it")
        XCTAssertEqual(LocalRemuxStrategyChoice.choice(for: Self.testChoice.id).displayName, "Renamed")
        // Restore for any later assertions in this run.
        LocalRemuxStrategyChoice.registerDynamic(Self.testChoice)
    }

    func testPreferencesStorePersistsDynamicStrategyID() {
        let defaults = UserDefaults(suiteName: "LocalRemuxStrategyChoiceTests.\(UUID().uuidString)")!
        let store = PlaybackPreferencesStore(defaults: defaults)
        store.saveLocalRemuxStrategyID(Self.testChoice.id)
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), Self.testChoice.id)
    }

    func testPreferencesStoreNormalisesUnknownToDisabled() {
        let defaults = UserDefaults(suiteName: "LocalRemuxStrategyChoiceTests.\(UUID().uuidString)")!
        let store = PlaybackPreferencesStore(defaults: defaults)
        store.saveLocalRemuxStrategyID("bogus.engine")
        XCTAssertEqual(store.loadLocalRemuxStrategyID(), LocalRemuxStrategyChoice.disabledID)
    }
}
