import XCTest
@testable import CoreModels

/// Tests for the stale-while-revalidate disk cache that paints the Music landing
/// page instantly from the last merged snapshot.
final class MusicLandingCacheTests: XCTestCase {

    private func makeCache(maxAge: TimeInterval = 60 * 60) -> (MusicLandingCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLandingCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = MusicLandingCache(directory: dir, maxEntries: 4, maxAge: maxAge)
        return (cache, dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoreThenReadRoundTrips() async {
        let (cache, dir) = makeCache()
        defer { cleanup(dir) }

        let snapshot = MusicLandingCache.Snapshot(
            recentlyPlayed: [MusicAlbum(id: "1", title: "Rumours", artistName: "Fleetwood Mac")],
            albums: [MusicAlbum(id: "2", title: "Blue", artistName: "Joni Mitchell")],
            artists: [MusicArtist(id: "a1", name: "Queen")],
            playlists: [MusicPlaylist(id: "p1", title: "Roadtrip")]
        )
        await cache.store(snapshot, for: "key")

        let read = await cache.snapshot(for: "key")
        XCTAssertEqual(read?.albums.first?.title, "Blue")
        XCTAssertEqual(read?.recentlyPlayed.first?.title, "Rumours")
        XCTAssertEqual(read?.artists.first?.name, "Queen")
        XCTAssertEqual(read?.playlists.first?.title, "Roadtrip")
    }

    func testMissReturnsNil() async {
        let (cache, dir) = makeCache()
        defer { cleanup(dir) }
        let read = await cache.snapshot(for: "absent")
        XCTAssertNil(read)
    }

    func testExpiredSnapshotIsTreatedAsMiss() async {
        let (cache, dir) = makeCache(maxAge: -1) // already expired
        defer { cleanup(dir) }
        await cache.store(MusicLandingCache.Snapshot(albums: [MusicAlbum(id: "1", title: "X", artistName: "Y")]), for: "k")
        let read = await cache.snapshot(for: "k")
        XCTAssertNil(read, "a snapshot older than maxAge is a cache miss")
    }

    func testKeyIncludesVisibleLibrarySetAndIsOrderIndependent() {
        let a = MusicLandingCache.key(visibleLibraryIDs: ["plex": ["7", "8"], "jf": ["v1"]])
        let b = MusicLandingCache.key(visibleLibraryIDs: ["jf": ["v1"], "plex": ["8", "7"]])
        XCTAssertEqual(a, b, "key is independent of dictionary/array order")

        let hidden = MusicLandingCache.key(visibleLibraryIDs: ["plex": ["7"], "jf": ["v1"]])
        XCTAssertNotEqual(a, hidden, "hiding a library yields a different key (invalidates stale snapshot)")

        XCTAssertEqual(MusicLandingCache.key(visibleLibraryIDs: [:]), "all")
    }

    func testEphemeralCacheNeverPersists() async {
        let cache = MusicLandingCache.ephemeral
        await cache.store(MusicLandingCache.Snapshot(albums: [MusicAlbum(id: "1", title: "X", artistName: "Y")]), for: "k")
        let read = await cache.snapshot(for: "k")
        XCTAssertNil(read, "the ephemeral cache is a no-op")
    }
}
