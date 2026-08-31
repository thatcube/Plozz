import XCTest
@testable import CoreModels

final class NavigationStyleSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NavigationStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testUnsetProfileUsesNativeSidebar() {
        let store = NavigationStyleSettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.load(), .sidebar)
    }

    func testExplicitSelectionSurvivesDefaultChange() {
        let defaults = makeDefaults()
        let store = NavigationStyleSettingsStore(defaults: defaults)
        store.save(.rail)

        XCTAssertEqual(NavigationStyleSettingsStore(defaults: defaults).load(), .rail)
    }

    func testProfileNamespacesRemainIndependent() {
        let defaults = makeDefaults()
        let primary = NavigationStyleSettingsStore(defaults: defaults)
        let child = NavigationStyleSettingsStore(defaults: defaults, namespace: "child")

        primary.save(.tabBar)

        XCTAssertEqual(primary.load(), .tabBar)
        XCTAssertEqual(child.load(), .sidebar)
    }
}
