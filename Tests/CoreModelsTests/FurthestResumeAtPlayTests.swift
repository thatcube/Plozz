import XCTest
@testable import CoreModels

/// Verifies bug (b): Play must seek to the unified **furthest-progress** resume
/// across all servers, regardless of which server backs the chosen stream — so a
/// best-source switch can't rewind playback to 0 when the merged card shows
/// progress made on another server.
final class FurthestResumeAtPlayTests: XCTestCase {
    private func merged(sources: [MediaSourceRef]) -> MediaItem {
        MediaItem(id: "merged", title: "Dune", kind: .movie, resumePosition: 0, sources: sources)
    }

    func testPlayUsesFurthestProgressNotChosenServersOwn() {
        // Watched 4 min on Jellyfin; the Plex copy was never started (resume 0).
        let jelly = MediaSourceRef(accountID: "jellyfin", itemID: "j1", resumePosition: 240)
        let plex = MediaSourceRef(accountID: "plex", itemID: "p1", resumePosition: 0)
        let item = merged(sources: [jelly, plex])

        // Best-source routing picks the Plex copy (its own resume is 0)...
        let routed = MediaItem.retargetedForPlayback(
            item: item, sources: [jelly, plex], activeAccountID: "plex", versionID: nil
        )

        // ...but Play must still resume at the furthest cross-server progress (240s).
        XCTAssertEqual(routed.resumePosition, 240)
        XCTAssertEqual(routed.sourceAccountID, "plex", "Still streams from the chosen server")
    }

    func testFurthestResumePicksMaxAcrossServers() {
        let a = MediaSourceRef(accountID: "a", itemID: "x", resumePosition: 120)
        let b = MediaSourceRef(accountID: "b", itemID: "y", resumePosition: 600)
        XCTAssertEqual(MediaItemMerger.playbackResumePosition(from: [a, b]), 600)
    }

    func testPlayedAnywhereResumesFromZero() {
        // A finished copy means the unified state is "played" → a rewatch starts at 0.
        let watched = MediaSourceRef(accountID: "a", itemID: "x", isPlayed: true)
        let other = MediaSourceRef(accountID: "b", itemID: "y", resumePosition: 300)
        XCTAssertNil(MediaItemMerger.playbackResumePosition(from: [watched, other]),
                     "Unified played state rewatches from the start, not a stale resume")
    }

    func testSingleServerItemKeepsItsOwnResume() {
        // No cross-server sources → reconciliation is a no-op and the item's own
        // resume is preserved.
        var item = MediaItem(id: "solo", title: "Solo", kind: .movie, resumePosition: 90)
        item = item.reconcilingPlaybackResume(acrossSources: [])
        XCTAssertEqual(item.resumePosition, 90)
    }
}
