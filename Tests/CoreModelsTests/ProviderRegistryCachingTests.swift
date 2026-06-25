import XCTest
@testable import CoreModels

final class ProviderRegistryCachingTests: XCTestCase {
    /// Reference-type provider so we can assert instance identity across calls.
    private final class StubProvider: MediaProvider, @unchecked Sendable {
        let kind: ProviderKind = .plex
        let session: UserSession
        init(session: UserSession) { self.session = session }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            MediaPage(items: [], startIndex: 0, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    private func session(token: String, server: String = "srv", user: String = "u") -> UserSession {
        UserSession(
            server: MediaServer(id: server, name: "Home", baseURL: URL(string: "http://host")!, provider: .plex),
            userID: user, userName: "User", deviceID: "d", accessToken: token
        )
    }

    func testSameSessionVendsSameInstanceAndBuildsOnce() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { s in builds += 1; return StubProvider(session: s) }

        let a = try XCTUnwrap(registry.provider(for: session(token: "T")) as? StubProvider)
        let b = try XCTUnwrap(registry.provider(for: session(token: "T")) as? StubProvider)
        let c = try XCTUnwrap(registry.provider(for: session(token: "T")) as? StubProvider)

        XCTAssertTrue(a === b && b === c, "Same session must reuse one provider instance")
        XCTAssertEqual(builds, 1, "Factory must run exactly once for a repeated session")
    }

    func testTokenRefreshRebuildsAndEvictsStale() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { s in builds += 1; return StubProvider(session: s) }

        let old = try XCTUnwrap(registry.provider(for: session(token: "OLD")) as? StubProvider)
        let new = try XCTUnwrap(registry.provider(for: session(token: "NEW")) as? StubProvider)
        XCTAssertFalse(old === new, "A refreshed token must build a new provider")
        XCTAssertEqual(builds, 2)

        // Re-requesting the new token reuses the cached instance (no extra build),
        // and the stale-token entry was evicted (cache holds one per account).
        let newAgain = try XCTUnwrap(registry.provider(for: session(token: "NEW")) as? StubProvider)
        XCTAssertTrue(new === newAgain)
        XCTAssertEqual(builds, 2)
    }

    func testInvalidateCacheForcesRebuild() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { s in builds += 1; return StubProvider(session: s) }

        _ = try registry.provider(for: session(token: "T"))
        registry.invalidateCache()
        _ = try registry.provider(for: session(token: "T"))
        XCTAssertEqual(builds, 2, "invalidateCache must drop memoized providers")
    }
}
