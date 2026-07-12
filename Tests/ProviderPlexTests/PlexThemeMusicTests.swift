import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderPlex

final class PlexThemeMusicTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "srv",
                name: "Home",
                baseURL: URL(string: "https://plex.host:32400")!,
                provider: .plex
            ),
            userID: "u1",
            userName: "Alice",
            deviceID: "d1",
            accessToken: "SECRET_TOKEN"
        )
    }

    func testThemeMusicBuildsCredentialFreeStreamFromMetadata() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/movie1", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"movie1","type":"movie","title":"The Movie",
           "theme":"/library/metadata/movie1/theme/9876"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let resolved = try await provider.themeMusic(for: "movie1")
        let theme = try XCTUnwrap(resolved)
        XCTAssertEqual(theme.itemID, "movie1")
        XCTAssertEqual(theme.title, "The Movie")
        guard case .authenticatedHTTP(let locator) = theme.playbackSource else {
            return XCTFail("expected authenticated HTTP theme source")
        }
        XCTAssertEqual(locator.itemID, "movie1")
        XCTAssertEqual(locator.purpose, .themeMusic)
        XCTAssertEqual(locator.deliveryMode, .directFile)
        XCTAssertEqual(locator.resource.pathBase, .configuredBaseURL)
        XCTAssertEqual(
            locator.resource.path,
            "library/metadata/movie1/theme/9876"
        )
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
            }
        )
    }

    func testThemeMusicFallsBackToArchiveByTVDBGuid() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/show1", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"show1","type":"show","title":"Sailor Moon",
           "Guid":[{"id":"tvdb://78650"},{"id":"imdb://tt0103369"}]}
        ]}}
        """)
        let archiveURL = URL(string: "https://tvthemes.plexapp.com/78650.mp3")!
        let provider = PlexProvider(
            session: makeSession(),
            http: stub,
            themeArchiveResolver: { $0 == "78650" ? archiveURL : nil }
        )

        let resolved = try await provider.themeMusic(for: "show1")
        let theme = try XCTUnwrap(resolved)
        XCTAssertEqual(theme.playbackSource.publicURL, archiveURL)
        XCTAssertEqual(theme.title, "Sailor Moon")
    }

    func testThemeMusicGracefullyReturnsNilOnMiss() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/show1", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"show1","type":"show","title":"No Theme"}
        ]}}
        """)
        let provider = PlexProvider(
            session: makeSession(),
            http: stub,
            themeArchiveResolver: { _ in nil }
        )

        let theme = try await provider.themeMusic(for: "show1")
        XCTAssertNil(theme)
    }
}
