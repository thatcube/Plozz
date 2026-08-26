import XCTest
import CoreModels
@testable import AppRuntime

/// Covers the intent built when a viewer takes a title off Continue Watching.
///
/// The distinction the whole action rests on: this clears where they had got to,
/// and says nothing about whether they watched it. Marking it watched would also
/// empty the row, and would additionally tell every server — and any tracker
/// mirroring them — that the title was finished, corrupting the history that
/// decides what to recommend next.
final class RemoveFromContinueWatchingMutationTests: XCTestCase {

    private func movie(account: String = "plex", id: String = "px-1") -> MediaItem {
        var item = MediaItem(id: id, title: "Abandoned", kind: .movie, resumePosition: 600)
        item.sourceAccountID = account
        item.sources = [MediaSourceRef(accountID: account, itemID: id, providerKind: .plex)]
        return item
    }

    func testClearsTheResumePointWithoutClaimingItWasWatched() {
        let mutation = WatchMutationFactory.removeFromContinueWatching(
            item: movie(),
            primaryAccountID: "plex"
        )

        XCTAssertEqual(mutation?.clearResume, true)
        XCTAssertNil(mutation?.played, "Taking it off the row is not a claim about having seen it")
        XCTAssertNil(mutation?.resumePosition, "There is no position to write — it is being removed")
    }

    /// Nothing was watched, so nothing is scrobbled. A tracker learning about an
    /// abandoned film would be worse than it learning nothing.
    func testDoesNotMirrorToTrackers() {
        let mutation = WatchMutationFactory.removeFromContinueWatching(
            item: movie(),
            primaryAccountID: "plex"
        )
        XCTAssertNil(mutation?.trakt)
    }

    /// Resume state that converges on one server and not another has not really
    /// been removed — it just moved.
    func testFansOutToEveryServerHoldingTheTitle() {
        var item = movie()
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "px-1", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin", itemID: "jf-1", providerKind: .jellyfin)
        ]

        let mutation = WatchMutationFactory.removeFromContinueWatching(
            item: item,
            primaryAccountID: "plex"
        )

        XCTAssertEqual(
            Set(mutation?.targets.map(\.id) ?? []),
            ["plex:px-1", "jellyfin:jf-1"]
        )
    }

    /// With cross-server sync switched off the viewer has asked for exactly one
    /// server to be touched, and that applies here as it does to every other
    /// watch action.
    func testHonoursCrossServerSyncBeingOff() {
        var item = movie()
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "px-1", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin", itemID: "jf-1", providerKind: .jellyfin)
        ]

        let mutation = WatchMutationFactory.removeFromContinueWatching(
            item: item,
            primaryAccountID: "plex",
            crossServerSync: false
        )

        XCTAssertEqual(mutation?.targets.map(\.id), ["plex:px-1"])
    }

    func testNoMutationWithoutAnyTarget() {
        var orphan = MediaItem(id: "x", title: "No server", kind: .movie, resumePosition: 60)
        orphan.sourceAccountID = nil
        orphan.sources = []

        XCTAssertNil(
            WatchMutationFactory.removeFromContinueWatching(item: orphan, primaryAccountID: nil)
        )
    }
}
