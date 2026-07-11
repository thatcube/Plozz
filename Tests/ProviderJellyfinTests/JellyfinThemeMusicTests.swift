import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderJellyfin

final class JellyfinThemeMusicTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "s",
                name: "Home",
                baseURL: URL(string: "http://host:8096")!,
                provider: .jellyfin
            ),
            userID: "u1",
            userName: "Alice",
            deviceID: "d1",
            accessToken: "SECRET_TOKEN"
        )
    }

    func testThemeMusicMapsFirstServerThemeToTokenedStream() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/movie1/ThemeSongs", json: """
        {"Items":[
          {"Id":"song1","Name":"Main Title","Type":"Audio"},
          {"Id":"song2","Name":"End Credits","Type":"Audio"}
        ],"TotalRecordCount":2}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let resolved = try await provider.themeMusic(for: "movie1")
        let theme = try XCTUnwrap(resolved)
        XCTAssertEqual(theme.itemID, "movie1")
        XCTAssertEqual(theme.title, "Main Title")
        XCTAssertTrue(theme.streamURL.path.hasSuffix("/Audio/song1/universal"))
        let query = URLComponents(
            url: theme.streamURL,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        XCTAssertTrue(
            query.contains { $0.name == "api_key" && $0.value == "SECRET_TOKEN" }
        )
    }

    func testThemeMusicRequestsParentInheritance() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/ep1/ThemeSongs", json: """
        {"Items":[{"Id":"song1","Name":"Theme","Type":"Audio"}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.themeMusic(for: "ep1")
        let query = stub.queryItems(forPathSuffix: "/ThemeSongs") ?? []
        XCTAssertTrue(
            query.contains { $0.name == "InheritFromParent" && $0.value == "true" }
        )
    }

    func testThemeMusicFallsBackToArchiveByTVDBID() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/show1/ThemeSongs", json: """
        {"Items":[],"TotalRecordCount":0}
        """)
        stub.stub(pathSuffix: "/Users/u1/Items/show1", json: """
        {"Id":"show1","Name":"Sailor Moon","Type":"Series","ProviderIds":{"Tvdb":"78650"}}
        """)
        let archiveURL = URL(string: "https://tvthemes.plexapp.com/78650.mp3")!
        let provider = JellyfinProvider(
            session: makeSession(),
            http: stub,
            themeArchiveResolver: { $0 == "78650" ? archiveURL : nil }
        )

        let resolved = try await provider.themeMusic(for: "show1")
        let theme = try XCTUnwrap(resolved)
        XCTAssertEqual(theme.streamURL, archiveURL)
        XCTAssertEqual(theme.title, "Sailor Moon")
    }

    func testThemeMusicGracefullyReturnsNilOnMiss() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/show1/ThemeSongs", json: """
        {"Items":[],"TotalRecordCount":0}
        """)
        stub.stub(pathSuffix: "/Users/u1/Items/show1", json: """
        {"Id":"show1","Name":"Arcane","Type":"Series","ProviderIds":{"Tvdb":"384640"}}
        """)
        let provider = JellyfinProvider(
            session: makeSession(),
            http: stub,
            themeArchiveResolver: { _ in nil }
        )

        let theme = try await provider.themeMusic(for: "show1")
        XCTAssertNil(theme)
    }
}
