import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Jellyfin's Resume / NextUp / Latest feeds don't report each item's owning
/// library (an episode's `ParentId` is its season), so the provider attributes —
/// and Home-filters — items by fetching **scoped per library** via `ParentId`
/// and stamping each result's `libraryID`. These pin down: the scoped path sends
/// `ParentId`, stamps `libraryID`, the unscoped path (nil) leaves it nil
/// (fail-open) and sends no `ParentId`, and an empty scope short-circuits.
final class JellyfinLibraryScopingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    private func parentIDs(_ stub: StubHTTPClient, pathSuffix: String) -> [String] {
        stub.sentQueryItems.enumerated().compactMap { index, items in
            guard stub.sentPaths[index].hasSuffix(pathSuffix) else { return nil }
            return items.first(where: { $0.name == "ParentId" })?.value
        }
    }

    // MARK: Continue Watching

    func testScopedContinueWatchingSendsParentIDAndStampsLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
        {"Items":[{"Id":"i1","Name":"Movie","Type":"Movie",
        "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}],"TotalRecordCount":1}
        """)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: ["LIB1"])
        XCTAssertEqual(items.map(\.id), ["i1"])
        XCTAssertEqual(items.first?.libraryID, "LIB1",
                       "A scoped fetch must stamp each item with the library it was fetched from")
        XCTAssertEqual(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume"), ["LIB1"])
    }

    func testScopedContinueWatchingFetchesEachVisibleLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.continueWatching(limit: 10, inLibraries: ["A", "B"])
        XCTAssertEqual(Set(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume")), ["A", "B"],
                       "Scoped Continue Watching must request each visible library")
    }

    func testNilScopeUsesUnscopedFeedAndLeavesLibraryNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
        {"Items":[{"Id":"i1","Name":"Movie","Type":"Movie",
        "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}],"TotalRecordCount":1}
        """)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: nil)
        XCTAssertEqual(items.map(\.id), ["i1"])
        XCTAssertNil(items.first?.libraryID, "Unscoped fetch must leave libraryID nil (fail-open)")
        XCTAssertTrue(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume").isEmpty,
                      "Unscoped fetch must not send a ParentId")
    }

    func testEmptyScopeReturnsNothingWithoutRequesting() async throws {
        let stub = StubHTTPClient()
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: [])
        XCTAssertTrue(items.isEmpty, "Hiding every library must yield an empty row")
        XCTAssertTrue(stub.sentPaths.isEmpty, "An empty scope must short-circuit before any request")
    }

    // MARK: Latest

    func testScopedLatestSendsParentIDAndStampsLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Latest", json: """
        [{"Id":"m1","Name":"Dune","Type":"Movie"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10, inLibraries: ["LIB2"])
        XCTAssertEqual(latest.map(\.id), ["m1"])
        XCTAssertEqual(latest.first?.libraryID, "LIB2")
        XCTAssertEqual(parentIDs(stub, pathSuffix: "/Users/u1/Items/Latest"), ["LIB2"])
    }

    func testNilScopeLatestLeavesLibraryNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Latest", json: """
        [{"Id":"m1","Name":"Dune","Type":"Movie"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10, inLibraries: nil)
        XCTAssertEqual(latest.map(\.id), ["m1"])
        XCTAssertNil(latest.first?.libraryID)
        XCTAssertTrue(parentIDs(stub, pathSuffix: "/Users/u1/Items/Latest").isEmpty)
    }
}
