import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinSearchCatalogTests: XCTestCase {
    private func session() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "server",
                name: "Home",
                baseURL: URL(string: "http://host:8096")!,
                provider: .jellyfin
            ),
            userID: "user",
            userName: "Alice",
            deviceID: "device",
            accessToken: "TOKEN"
        )
    }

    func testRichEpisodePageMapsMetadataTimestampAndCursor() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/user/Items", json: """
        {"Items":[
          {"Id":"e1","Name":"Dinner","Type":"Episode",
           "Overview":"Friends wait for a restaurant table.",
           "SeriesName":"Example Show","SeriesId":"series","SeasonId":"season",
           "ParentIndexNumber":2,"IndexNumber":11,
           "Genres":["Comedy"],"Tags":["Bottle Episode"],
           "People":[{"Id":"p1","Name":"Actor","Type":"Actor","Role":"Friend"}],
           "ProviderIds":{"Tvdb":"123"}}
        ],"TotalRecordCount":2}
        """)
        let provider = JellyfinProvider(session: session(), http: stub)

        let page = try await provider.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: "shows",
                kind: .episode,
                limit: 1
            )
        )
        XCTAssertEqual(page.records.map(\.item.id), ["e1"])
        XCTAssertEqual(page.records.first?.item.libraryID, "shows")
        XCTAssertEqual(page.records.first?.item.parentTitle, "Example Show")
        XCTAssertEqual(page.records.first?.item.seasonNumber, 2)
        XCTAssertEqual(page.records.first?.item.episodeNumber, 11)
        XCTAssertEqual(page.records.first?.item.genres, ["Comedy"])
        XCTAssertNotNil(page.nextCursor)

        let query = stub.queryItems(forPathSuffix: "/Users/user/Items") ?? []
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(values["ParentId"], "shows")
        XCTAssertEqual(values["IncludeItemTypes"], "Episode")
        XCTAssertEqual(values["Recursive"], "true")
        XCTAssertEqual(values["SortBy"], "DateCreated,SortName")
        XCTAssertTrue(values["Fields"]?.contains("Overview") == true)

        _ = try await provider.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: "shows",
                kind: .episode,
                cursor: page.nextCursor,
                limit: 1
            )
        )
        let resumed = stub.queryItems(forPathSuffix: "/Users/user/Items") ?? []
        XCTAssertEqual(resumed.first(where: { $0.name == "StartIndex" })?.value, "1")
    }
}
