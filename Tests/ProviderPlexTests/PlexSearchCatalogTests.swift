import XCTest
import CoreModels
@testable import ProviderPlex

final class PlexSearchCatalogTests: XCTestCase {
    private func session() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "server",
                name: "Home",
                baseURL: URL(string: "https://plex.host:32400")!,
                provider: .plex
            ),
            userID: "user",
            userName: "Alice",
            deviceID: "device",
            accessToken: "TOKEN"
        )
    }

    func testEpisodePageUsesTypeFourAndMapsRichMetadata() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/5/all", json: """
        {"MediaContainer":{"totalSize":2,"size":1,"offset":0,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"Dinner",
           "grandparentTitle":"Example Show","grandparentRatingKey":"show",
           "parentRatingKey":"season","parentIndex":2,"index":11,
           "summary":"Friends wait for a restaurant table.",
           "Genre":[{"tag":"Comedy"}],"Tag":[{"tag":"Bottle Episode"}],
           "Role":[{"id":1,"tag":"Actor","role":"Friend"}],
           "Director":[{"id":2,"tag":"Director"}],
           "Guid":[{"id":"tvdb://123"}]}
        ]}}
        """)
        let provider = PlexProvider(session: session(), http: stub)

        let page = try await provider.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: "5",
                kind: .episode,
                limit: 1
            )
        )
        XCTAssertEqual(page.records.map(\.item.id), ["e1"])
        XCTAssertEqual(page.records.first?.item.libraryID, "5")
        XCTAssertEqual(page.records.first?.item.parentTitle, "Example Show")
        XCTAssertEqual(page.records.first?.item.seasonNumber, 2)
        XCTAssertEqual(page.records.first?.item.episodeNumber, 11)
        XCTAssertEqual(page.records.first?.item.genres, ["Comedy"])
        XCTAssertEqual(page.records.first?.item.people.count, 2)
        XCTAssertNotNil(page.nextCursor)

        let query = stub.queryItems(forPathSuffix: "/library/sections/5/all") ?? []
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "4")
        XCTAssertEqual(
            query.first(where: { $0.name == "X-Plex-Container-Start" })?.value,
            "0"
        )
        XCTAssertEqual(query.first(where: { $0.name == "includeGuids" })?.value, "1")

        _ = try await provider.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: "5",
                kind: .episode,
                cursor: page.nextCursor,
                limit: 1
            )
        )
        let resumed = stub.queryItems(forPathSuffix: "/library/sections/5/all") ?? []
        XCTAssertEqual(
            resumed.first(where: { $0.name == "X-Plex-Container-Start" })?.value,
            "1"
        )
    }
}
