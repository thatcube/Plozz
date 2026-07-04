import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Verifies the Plex alphabet fast-scroll index. Plex's `firstCharacter` facet
/// returns one entry per present letter (ascending, with its item count), so a
/// single request yields every offset — meaning, unlike Jellyfin, the real
/// offsets are assertable here.
final class PlexLetterIndexTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// 2 items under "#", 3 under "A", 5 under "C" = 10 total, ascending.
    private func stubFacet() -> StubHTTPClient {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/firstCharacter", json: """
        {"MediaContainer":{"size":3,"Directory":[
          {"key":"#","title":"#","titleSort":"#","size":2},
          {"key":"A","title":"A","titleSort":"A","size":3},
          {"key":"C","title":"C","titleSort":"C","size":5}
        ]}}
        """)
        return stub
    }

    func testNameSortAscendingBuildsCumulativeOffsets() async throws {
        let provider = PlexProvider(session: makeSession(), http: stubFacet())
        let entries = try await provider.letterIndex(
            in: "3", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .name, direction: .ascending)
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "#", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 2),
            LibraryLetterIndexEntry(letter: "C", startIndex: 5)
        ])
    }

    func testNameSortDescendingMirrorsOffsets() async throws {
        let provider = PlexProvider(session: makeSession(), http: stubFacet())
        let entries = try await provider.letterIndex(
            in: "3", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .name, direction: .descending)
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "C", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 5),
            LibraryLetterIndexEntry(letter: "#", startIndex: 8)
        ])
    }

    func testNonNameSortReturnsEmptyWithoutFacetRequest() async throws {
        let stub = stubFacet()
        let provider = PlexProvider(session: makeSession(), http: stub)
        let entries = try await provider.letterIndex(
            in: "3", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .releaseDate, direction: .ascending)
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty, "Non-name sorts must not hit the firstCharacter facet")
    }
}
