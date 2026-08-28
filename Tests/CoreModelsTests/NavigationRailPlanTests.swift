import XCTest
@testable import CoreModels

/// The rail's arrangement rules. These are the ones a user notices immediately if
/// they're wrong — a library that vanishes when a server is added, an order that
/// resets, or a hidden library that comes back on relaunch.
final class NavigationRailPlanTests: XCTestCase {

    private func library(
        _ id: String,
        title: String,
        account: String,
        kind: MediaItemKind = .movie,
        isMusic: Bool = false
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: account,
            serverName: "Server \(account)",
            providerKind: .jellyfin,
            library: MediaLibrary(
                id: id,
                title: title,
                kind: kind,
                isMusic: isMusic,
                sourceAccountID: account
            )
        )
    }

    // MARK: Available keys

    func testAvailableKeysLeadWithAllLibrariesAndExcludeMusic() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Songs", account: "a", isMusic: true),
            library("3", title: "Shows", account: "a", kind: .series)
        ]
        XCTAssertEqual(
            NavigationRailPlan.availableKeys(visibleLibraries: libraries),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )
    }

    // MARK: Default arrangement

    func testDefaultLayoutShowsEverythingInDiscoveryOrder() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series)
        ]
        let entries = NavigationRailPlan.entries(visibleLibraries: libraries, layout: .default)
        XCTAssertEqual(
            entries.map(\.key),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:2"]
        )
        XCTAssertTrue(entries[0].isAllLibraries)
        XCTAssertEqual(entries[1].library?.library.title, "Movies")
    }

    func testCombinedEntryIsOmittedWhenThereIsNothingToCombine() {
        // One library means "All Libraries" would just be a duplicate of it, and
        // zero means it would open an empty grid.
        let single = [library("1", title: "Movies", account: "a")]
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: single, layout: .default).map(\.key),
            ["a:1"]
        )
        XCTAssertTrue(NavigationRailPlan.entries(visibleLibraries: [], layout: .default).isEmpty)
    }

    // MARK: Reordering + hiding

    func testExplicitOrderIsHonouredAndNewLibrariesAppendRatherThanVanish() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
            library("3", title: "Anime", account: "a", kind: .series)
        ]
        var layout = NavigationLibraryLayout(
            order: ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1"]
        )
        // "a:3" was discovered after the arrangement was saved.
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )

        layout.setVisible(false, for: "a:1")
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:3"]
        )
    }

    func testApplyingAnEditPreservesTheArrangementOfAnOfflineLibrary() {
        // A server that is briefly unreachable must not cost the viewer the
        // arrangement they set for its libraries.
        var layout = NavigationLibraryLayout(
            order: ["a:1", "b:1", "a:2"],
            hiddenKeys: ["b:1"]
        )
        let available = ["a:1", "a:2"]
        let edited = OrderedVisibilityList.Sections(enabled: ["a:2"], disabled: ["a:1"])
        layout.apply(edited, available: available)

        XCTAssertEqual(layout.order, ["a:2", "b:1", "a:1"])
        XCTAssertEqual(layout.hiddenKeys, ["b:1", "a:1"])
    }

    func testApplyingAnEditUnhidesALibraryMovedBackAboveTheDivider() {
        var layout = NavigationLibraryLayout(order: ["a:1", "a:2"], hiddenKeys: ["a:2"])
        let available = ["a:1", "a:2"]
        layout.apply(
            OrderedVisibilityList.Sections(enabled: ["a:1", "a:2"], disabled: []),
            available: available
        )
        XCTAssertTrue(layout.hiddenKeys.isEmpty)
        XCTAssertEqual(layout.visibleKeys(available: available), ["a:1", "a:2"])
    }

    // MARK: Selection pruning

    func testSelectionFallsBackToHomeWhenItsDestinationIsGone() {
        let entries = NavigationRailPlan.entries(
            visibleLibraries: [
                library("1", title: "Movies", account: "a"),
                library("2", title: "Shows", account: "a", kind: .series)
            ],
            layout: .default
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.library("a:1"), entries: entries, hasMusic: false),
            .library("a:1")
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.library("gone:9"), entries: entries, hasMusic: false),
            .home
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.music, entries: entries, hasMusic: false),
            .home
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.music, entries: entries, hasMusic: true),
            .music
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.allLibraries, entries: entries, hasMusic: false),
            .allLibraries
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.allLibraries, entries: [], hasMusic: false),
            .home
        )
    }

    // MARK: Scene-storage round trip

    func testDestinationStorageValueRoundTrips() {
        let cases: [NavigationRailDestination] = [
            .home, .search, .music, .settings, .allLibraries, .library("acct:lib:with:colons")
        ]
        for destination in cases {
            XCTAssertEqual(
                NavigationRailDestination(storageValue: destination.storageValue),
                destination
            )
        }
        XCTAssertNil(NavigationRailDestination(storageValue: "nonsense"))
    }
}
