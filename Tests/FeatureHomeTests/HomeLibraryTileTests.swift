#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import FeatureHome

/// Tests the Home Libraries-row tile subtitle, which must surface enough of
/// `serverName`/`accountName` to tell same-named, un-merged tiles apart.
final class HomeLibraryTileTests: XCTestCase {
    private func aggregated(
        account: String,
        accountName: String,
        server: String,
        libraryID: String,
        title: String
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: accountName,
            serverName: server,
            providerKind: .plex,
            library: MediaLibrary(id: libraryID, title: title, kind: .movie).taggingSource(account)
        )
    }

    func testSubtitleShowsServerWhenServersDiffer() {
        let a = aggregated(account: "a", accountName: "Bob", server: "Plex A", libraryID: "1", title: "Movies")
        let b = aggregated(account: "b", accountName: "Alice", server: "Jelly B", libraryID: "2", title: "Movies")
        let all = [a, b]
        // Server names already distinguish them — keep the subtitle uncluttered.
        XCTAssertEqual(HomeView.librarySubtitle(for: a, in: all), "Plex A")
        XCTAssertEqual(HomeView.librarySubtitle(for: b, in: all), "Jelly B")
    }

    func testSubtitleAddsAccountWhenServerNameIsAmbiguous() {
        // Two logins to the *same* server name (e.g. two Plex Home users): the
        // server name alone can't tell their same-named libraries apart, so add
        // the user.
        let a = aggregated(account: "a", accountName: "Bob", server: "Home Server", libraryID: "1", title: "Movies")
        let b = aggregated(account: "b", accountName: "Alice", server: "Home Server", libraryID: "2", title: "Movies")
        let all = [a, b]
        XCTAssertEqual(HomeView.librarySubtitle(for: a, in: all), "Home Server · Bob")
        XCTAssertEqual(HomeView.librarySubtitle(for: b, in: all), "Home Server · Alice")
    }

    func testSubtitleFallsBackToAccountWhenServerNameMissing() {
        let a = aggregated(account: "a", accountName: "Bob", server: "", libraryID: "1", title: "Movies")
        XCTAssertEqual(HomeView.librarySubtitle(for: a, in: [a]), "Bob")
    }
}
#endif
