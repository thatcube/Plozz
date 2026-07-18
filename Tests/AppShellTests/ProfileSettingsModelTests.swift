import XCTest
import CoreModels
@testable import AppShell

/// Unit tests for ``ProfileSettingsModel`` — the per-profile settings facet split
/// out of ``AppState``. Verifies the two behaviours that used to live in
/// `AppState.rebuildSettingsModels()`: namespace-scoped (re)builds swap the
/// sub-models on profile switch, and injected models (the test path) are treated
/// as immutable and never rebuilt.
@MainActor
final class ProfileSettingsModelTests: XCTestCase {

    func testDefaultBuildIsNotTreatedAsInjected() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        XCTAssertFalse(model.usesInjectedModels)
    }

    func testRebuildSwapsSubModelInstances() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        let themeBefore = ObjectIdentifier(model.themeModel)
        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        // A non-injectable model (always built) must also swap.
        let heroBefore = ObjectIdentifier(model.heroSettingsModel)

        model.rebuild(namespace: "ns-b")

        XCTAssertNotEqual(themeBefore, ObjectIdentifier(model.themeModel))
        XCTAssertNotEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
        XCTAssertNotEqual(heroBefore, ObjectIdentifier(model.heroSettingsModel))
    }

    func testInjectedModelsAreNotRebuilt() {
        let injectedTheme = ThemeSettingsModel(store: ThemeSettingsStore(namespace: "seed"))
        let model = ProfileSettingsModel(namespace: "ns-a", themeModel: injectedTheme)
        XCTAssertTrue(model.usesInjectedModels)
        XCTAssertTrue(model.themeModel === injectedTheme)

        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        model.rebuild(namespace: "ns-b")

        // Rebuild is a no-op when models were injected: identity is preserved.
        XCTAssertTrue(model.themeModel === injectedTheme)
        XCTAssertEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
    }
}
