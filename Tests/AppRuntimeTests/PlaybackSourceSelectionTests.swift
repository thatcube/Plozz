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

/// The closest-server guarantee, which used to hold only when the item's own
/// server happened to be unplayable.
extension PlaybackSourceSelectionTests {
    func testPrefersTheLocalCopyOverAPlayableRemoteOrigin() {
        // A Continue Watching card carries whichever server's resume state won
        // the merge — for a shared title that can be a remote Jellyfin. Because
        // that origin was perfectly playable, the local Plex copy was never even
        // considered, and the card played over Tailscale.
        var remote = MediaSourceRef(
            accountID: "sister-jellyfin",
            itemID: "ep-remote",
            kind: .episode,
            providerKind: .jellyfin
        )
        remote.locality = .remote
        var local = MediaSourceRef(
            accountID: "my-plex",
            itemID: "ep-local",
            kind: .episode,
            providerKind: .plex
        )
        local.locality = .local

        var item = MediaItem(
            id: "ep-remote",
            title: "The Storm",
            kind: .episode,
            sourceAccountID: "sister-jellyfin"
        )
        item.sources = [remote, local]

        let selected = PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: [],
            identitySources: { _ in [] }
        )

        XCTAssertEqual(selected.selectedSourceAccountID, "my-plex")
        XCTAssertEqual(selected.id, "ep-local")
    }

    func testKeepsAnExplicitServerPickEvenWhenItIsRemote() {
        // Ranking must never override a deliberate choice — the user picked that
        // server in the detail page's picker.
        var remote = MediaSourceRef(
            accountID: "sister-jellyfin",
            itemID: "ep-remote",
            kind: .episode,
            providerKind: .jellyfin
        )
        remote.locality = .remote
        var local = MediaSourceRef(
            accountID: "my-plex",
            itemID: "ep-local",
            kind: .episode,
            providerKind: .plex
        )
        local.locality = .local

        var item = MediaItem(
            id: "ep-remote",
            title: "The Storm",
            kind: .episode,
            sourceAccountID: "sister-jellyfin"
        )
        item.sources = [remote, local]
        item.selectedSourceAccountID = "sister-jellyfin"
        item.explicitSourceSelection = true

        let selected = PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: [],
            identitySources: { _ in [] }
        )

        XCTAssertEqual(selected.selectedSourceAccountID, "sister-jellyfin")
    }
}
