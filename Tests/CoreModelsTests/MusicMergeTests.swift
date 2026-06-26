import XCTest
@testable import CoreModels

/// Tests for the unified, de-duplicated music library seam — the single place
/// that decides "same release across servers" and merges per-source lists into
/// one combined list while preserving provenance.
final class MusicMergeTests: XCTestCase {

    // MARK: Identity normalization

    func testNormalizeFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(MusicIdentity.normalize("Beyoncé"), MusicIdentity.normalize("BEYONCE"))
        XCTAssertEqual(MusicIdentity.normalize("Sgt. Pepper's"), MusicIdentity.normalize("Sgt Peppers"))
        XCTAssertEqual(MusicIdentity.normalize("  Hello   World  "), "hello world")
        XCTAssertEqual(MusicIdentity.normalize("AC/DC"), "acdc")
    }

    func testAlbumKeyIncludesArtistSoSameTitleDifferentArtistStayDistinct() {
        let a = MusicAlbum(id: "1", title: "Greatest Hits", artistName: "Queen")
        let b = MusicAlbum(id: "2", title: "Greatest Hits", artistName: "ABBA")
        XCTAssertNotEqual(MusicIdentity.key(for: a), MusicIdentity.key(for: b))
    }

    // MARK: Cross-server de-duplication

    func testAlbumsCollapseCrossServerDuplicateAndKeepProvenance() {
        let jellyfin = MusicAlbum(id: "jf-1", title: "Rumours", artistName: "Fleetwood Mac", sourceAccountID: "jellyfin")
        let plex = MusicAlbum(id: "px-9", title: "rumours", artistName: "FLEETWOOD MAC", sourceAccountID: "plex")

        let merged = MusicMerge.albums([jellyfin, plex])

        XCTAssertEqual(merged.count, 1, "the same album on two servers should appear once")
        let survivor = merged[0]
        XCTAssertEqual(survivor.id, "jf-1", "first occurrence is the primary")
        XCTAssertEqual(survivor.sources.count, 2, "both contributing sources are retained")
        XCTAssertTrue(survivor.sources.contains(MusicSourceRef(accountID: "jellyfin", itemID: "jf-1")))
        XCTAssertTrue(survivor.sources.contains(MusicSourceRef(accountID: "plex", itemID: "px-9")))
    }

    func testDistinctAlbumsAreNotMergedAndOrderIsStable() {
        let a = MusicAlbum(id: "1", title: "A", artistName: "X", sourceAccountID: "s1")
        let b = MusicAlbum(id: "2", title: "B", artistName: "X", sourceAccountID: "s1")
        let merged = MusicMerge.albums([a, b])
        XCTAssertEqual(merged.map(\.id), ["1", "2"])
        XCTAssertEqual(merged[0].sources, [MusicSourceRef(accountID: "s1", itemID: "1")])
    }

    func testArtistsAndPlaylistsAndGenresDeduplicate() {
        let artists = MusicMerge.artists([
            MusicArtist(id: "a1", name: "Radiohead", sourceAccountID: "jf"),
            MusicArtist(id: "a2", name: "radiohead", sourceAccountID: "px")
        ])
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists[0].sources.count, 2)

        let playlists = MusicMerge.playlists([
            MusicPlaylist(id: "p1", title: "Chill", sourceAccountID: "jf"),
            MusicPlaylist(id: "p2", title: "chill", sourceAccountID: "px")
        ])
        XCTAssertEqual(playlists.count, 1)

        let genres = MusicMerge.genres([
            MusicGenre(id: "g1", name: "Rock", sourceAccountID: "jf"),
            MusicGenre(id: "g2", name: "rock", sourceAccountID: "px")
        ])
        XCTAssertEqual(genres.count, 1)
    }

    // MARK: Recently played — cross-library recency ordering

    func testRecentlyPlayedMergeSortsByRecencyThenDedupsAndTrims() {
        let now = Date()
        let old = MusicAlbum(id: "old", title: "Old", artistName: "A", sourceAccountID: "jf",
                             lastPlayedAt: now.addingTimeInterval(-1000))
        let newest = MusicAlbum(id: "new", title: "New", artistName: "B", sourceAccountID: "px",
                                lastPlayedAt: now)
        let mid = MusicAlbum(id: "mid", title: "Mid", artistName: "C", sourceAccountID: "jf",
                             lastPlayedAt: now.addingTimeInterval(-500))
        // A duplicate of `newest` from the other server, played slightly earlier.
        let newestDup = MusicAlbum(id: "new-dup", title: "new", artistName: "b", sourceAccountID: "jf",
                                   lastPlayedAt: now.addingTimeInterval(-10))

        let rail = MusicMerge.recentlyPlayedAlbums([old, newest, mid, newestDup], limit: 2)

        XCTAssertEqual(rail.map(\.id), ["new", "mid"], "ordered by real recency across libraries, then trimmed")
        XCTAssertEqual(rail[0].sources.count, 2, "the duplicate contributes provenance to the survivor")
    }

    func testRecentlyPlayedKeepsUntimedAlbumsLast() {
        let now = Date()
        let timed = MusicAlbum(id: "t", title: "T", artistName: "A", lastPlayedAt: now)
        let untimed = MusicAlbum(id: "u", title: "U", artistName: "B")
        let rail = MusicMerge.recentlyPlayedAlbums([untimed, timed], limit: 10)
        XCTAssertEqual(rail.map(\.id), ["t", "u"])
    }

    func testLastPlayedAtRoundTripsThroughCodable() throws {
        let album = MusicAlbum(id: "1", title: "A", artistName: "X",
                               lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               sources: [MusicSourceRef(accountID: "s", itemID: "1")])
        let data = try JSONEncoder().encode(album)
        let decoded = try JSONDecoder().decode(MusicAlbum.self, from: data)
        XCTAssertEqual(decoded, album)
    }
}
