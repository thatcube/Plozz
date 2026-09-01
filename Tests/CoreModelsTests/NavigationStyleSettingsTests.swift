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

    func testLayoutStoreUsesInjectedPlatformDefaultWhenUnset() {
        let defaults = makeDefaults()
        let fallback = NavigationLibraryLayout(
            hiddenKeys: [NavigationLibraryLayout.watchlistKey]
        )
        let store = NavigationLibraryLayoutStore(
            defaults: defaults,
            defaultLayout: fallback
        )

        XCTAssertEqual(store.load(), fallback)

        var optedIn = fallback
        optedIn.setVisible(true, for: NavigationLibraryLayout.watchlistKey)
        store.save(optedIn)

        XCTAssertTrue(
            NavigationLibraryLayoutStore(
                defaults: defaults,
                defaultLayout: fallback
            ).load().isVisible(NavigationLibraryLayout.watchlistKey)
        )
    }

    @MainActor
    func testWatchlistVisibilityPersistsPerProfile() {
        let defaults = makeDefaults()
        func model(namespace: String?) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(
                    defaults: defaults,
                    namespace: namespace
                ),
                layoutStore: NavigationLibraryLayoutStore(
                    defaults: defaults,
                    namespace: namespace
                )
            )
        }

        let primary = model(namespace: nil)
        let child = model(namespace: "child")
        XCTAssertTrue(primary.showsWatchlist)
        XCTAssertTrue(child.showsWatchlist)

        primary.showsWatchlist = false

        XCTAssertFalse(model(namespace: nil).showsWatchlist)
        XCTAssertTrue(model(namespace: "child").showsWatchlist)
    }
}
