import XCTest
import CoreModels
@testable import AppRuntime

final class PlaybackSourceSelectionTests: XCTestCase {
    func testPlexDiscoverItemRetargetsToIndexedLocalCopy() {
        let discoverID = "5d7768881999bc0020dc8374"
        let item = MediaItem(
            id: discoverID,
            title: "Movie",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/\(discoverID)"],
            sourceAccountID: "plex-account"
        )
        let local = MediaSourceRef(
            accountID: "plex-account",
            itemID: "46498",
            kind: .movie,
            providerKind: .plex
        )

        let selected = PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: [],
            identitySources: { _ in [local] }
        )

        XCTAssertEqual(selected.id, "46498")
        XCTAssertEqual(selected.sourceAccountID, "plex-account")
        XCTAssertEqual(selected.selectedSourceAccountID, "plex-account")
    }

    /// An episode must never be retargeted onto its SERIES' ref. The identity
    /// index matches on title/provider ids, so a show and its episodes can
    /// surface each other's refs; `selectingSource` then rewrites `id` while
    /// keeping `kind`, producing an "episode" that carries a container id. The
    /// provider can't play a container — Plex answers notFound, Jellyfin 500 —
    /// so this surfaced as "Can't play this right now" for an owned title.
    func testEpisodeIsNotRetargetedOntoSeriesRef() {
        let episode = MediaItem(
            id: "46132",
            title: "Outside",
            kind: .episode,
            sourceAccountID: "plex-account"
        )
        let seriesRef = MediaSourceRef(
            accountID: "plex-account",
            itemID: "46124",
            kind: .series,
            providerKind: .plex
        )

        let selected = PlaybackSourceSelection.bestPlayItem(
            episode,
            accounts: [],
            identitySources: { _ in [seriesRef] }
        )

        XCTAssertEqual(
            selected.id,
            "46132",
            "an episode must keep its own id rather than adopt the series' ratingKey"
        )
    }

    /// The same boundary at the mutation itself, so no future caller can
    /// reintroduce the mismatch by bypassing the selection path.
    func testSelectingSourceRejectsCrossKindRef() {
        let episode = MediaItem(
            id: "46132",
            title: "Outside",
            kind: .episode,
            sourceAccountID: "plex-account"
        )
        let seriesRef = MediaSourceRef(
            accountID: "plex-account",
            itemID: "46124",
            kind: .series,
            providerKind: .plex
        )

        XCTAssertEqual(episode.selectingSource(seriesRef).id, "46132")
    }

    /// A legacy ref cached before `kind` existed is untyped, and must still work
    /// for the item's own source — otherwise this guard would break playback for
    /// anyone with a pre-`kind` cache.
    func testUntypedLegacyRefStillRetargets() {
        let movie = MediaItem(
            id: "discover-id",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "plex-account"
        )
        let untyped = MediaSourceRef(
            accountID: "plex-account",
            itemID: "46498",
            providerKind: .plex
        )

        XCTAssertEqual(movie.selectingSource(untyped).id, "46498")
    }
}
