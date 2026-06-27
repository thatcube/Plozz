#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import FeatureHome

/// Locks down `HomeRow.rows(for:isLibraryVisible:)`: the data-driven layout that
/// both the loaded Home view and (later) the skeleton/streaming view render from.
/// These assert the exact order + visibility rules the view previously applied
/// inline, so the refactor stays behaviour-preserving and the order/visibility
/// contract is protected before row customization is layered on.
final class HomeRowTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func library(account: String, id: String, title: String = "Movies") -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: account,
            serverName: "Server",
            providerKind: .plex,
            library: MediaLibrary(id: id, title: title, kind: .movie).taggingSource(account)
        )
    }

    private func content(
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        watchlist: [MediaItem] = [],
        libraries: [AggregatedLibrary] = []
    ) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: continueWatching,
            latest: latest,
            watchlist: watchlist,
            libraries: libraries
        )
    }

    func testEmptyContentProducesNoRows() {
        let rows = HomeRow.rows(for: content()) { _ in true }
        XCTAssertTrue(rows.isEmpty)
    }

    func testRowsAppearInFixedOrder() {
        let c = content(
            continueWatching: [item("cw")],
            latest: [item("lt")],
            watchlist: [item("wl")],
            libraries: [library(account: "a", id: "1")]
        )
        let rows = HomeRow.rows(for: c) { _ in true }
        XCTAssertEqual(rows.map(\.kind), [.continueWatching, .watchlist, .recentlyAdded, .libraries])
    }

    func testEmptyMediaRowsAreOmitted() {
        // Continue Watching empty, Recently Added present: only the populated row
        // survives (mirroring MediaRowView hiding itself when empty).
        let c = content(latest: [item("lt")])
        let rows = HomeRow.rows(for: c) { _ in true }
        XCTAssertEqual(rows.map(\.kind), [.recentlyAdded])
        XCTAssertEqual(rows.first?.items.map(\.id), ["lt"])
    }

    func testHiddenLibrariesAreFilteredOut() {
        let visible = library(account: "a", id: "1")
        let hidden = library(account: "b", id: "2")
        let c = content(libraries: [visible, hidden])
        let rows = HomeRow.rows(for: c) { $0 == visible.key }
        XCTAssertEqual(rows.map(\.kind), [.libraries])
        XCTAssertEqual(rows.first?.libraries.map(\.key), [visible.key])
    }

    func testLibrariesRowOmittedWhenAllHidden() {
        let c = content(libraries: [library(account: "a", id: "1")])
        let rows = HomeRow.rows(for: c) { _ in false }
        XCTAssertTrue(rows.isEmpty)
    }

    func testContinueWatchingUsesLandscapeStyleOthersPoster() {
        let c = content(
            continueWatching: [item("cw")],
            latest: [item("lt")],
            watchlist: [item("wl")]
        )
        let rows = HomeRow.rows(for: c) { _ in true }
        let styles = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.style) })
        XCTAssertEqual(styles[.continueWatching], .landscape)
        XCTAssertEqual(styles[.watchlist], .poster)
        XCTAssertEqual(styles[.recentlyAdded], .poster)
    }

    func testTitlesMatchKinds() {
        XCTAssertEqual(HomeRowKind.continueWatching.title, "Continue Watching")
        XCTAssertEqual(HomeRowKind.watchlist.title, "Watchlist")
        XCTAssertEqual(HomeRowKind.recentlyAdded.title, "Recently Added")
        XCTAssertEqual(HomeRowKind.libraries.title, "Libraries")
    }

    // MARK: - Per-item library visibility (hide a library everywhere on Home)

    private func taggedItem(_ id: String, account: String, library: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie, sourceAccountID: account, libraryID: library)
    }

    func testMediaRowItemsFromHiddenLibraryAreDropped() {
        // Two Continue Watching items: one from a hidden library, one visible.
        let c = content(continueWatching: [
            taggedItem("hidden", account: "a", library: "L2"),
            taggedItem("shown", account: "a", library: "L1")
        ])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertEqual(rows.map(\.kind), [.continueWatching])
        XCTAssertEqual(rows.first?.items.map(\.id), ["shown"],
                       "A hidden library's item must be suppressed from Continue Watching, not just the tiles")
    }

    func testUnattributedItemsStayVisibleFailOpen() {
        // An item without library provenance (item(_:) leaves libraryID nil) must
        // never be hidden, even by an all-hiding predicate.
        let c = content(latest: [item("noLibrary")])
        let rows = HomeRow.rows(for: c) { _ in false }
        XCTAssertEqual(rows.map(\.kind), [.recentlyAdded])
        XCTAssertEqual(rows.first?.items.map(\.id), ["noLibrary"])
    }

    func testMediaRowOmittedWhenEveryItemHidden() {
        // Recently Added holds only hidden-library items → the whole row disappears.
        let c = content(latest: [taggedItem("h1", account: "a", library: "L2")])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertTrue(rows.isEmpty, "A media row with no surviving items must be omitted entirely")
    }

    func testMergedCardVisibleIfAnyContributingLibraryVisible() {
        var merged = taggedItem("m", account: "plex", library: "P1")
        merged.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j", libraryID: "J9")
        ]
        let c = content(latest: [merged])
        // Plex library hidden, Jellyfin visible → merged card still shows.
        let rows = HomeRow.rows(for: c) { $0 == "jelly:J9" }
        XCTAssertEqual(rows.first?.items.map(\.id), ["m"])
    }
}
#endif
