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
}
#endif
