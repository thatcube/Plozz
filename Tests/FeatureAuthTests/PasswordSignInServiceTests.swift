import XCTest
import CoreModels
@testable import FeatureAuth

final class PasswordSignInServiceTests: XCTestCase {
    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin)

    func testSignInBuildsSession() async throws {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":"srv","User":{"Id":"u1","Name":"Alice"}}
        """)
        let service = PasswordSignInService(server: server, deviceID: "dev1", http: stub)

        let session = try await service.signIn(username: "alice", password: "pw")
        XCTAssertEqual(session.accessToken, "TOK")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.userName, "Alice")
        XCTAssertEqual(session.deviceID, "dev1")
        XCTAssertEqual(session.server.id, "srv")
        XCTAssertEqual(session.server.baseURL, server.baseURL)
    }

    func testSignInFallsBackToSelectedServerIDWhenServerOmitsIt() async throws {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":null,"User":{"Id":"u1","Name":"Alice"}}
        """)
        let service = PasswordSignInService(server: server, deviceID: "dev1", http: stub)

        let session = try await service.signIn(username: "alice", password: "pw")
        XCTAssertEqual(session.server.id, "s")
    }

    func testEmbySignInPreservesProviderIdentity() async throws {
        let embyServer = MediaServer(
            id: "emby",
            name: "Emby Home",
            baseURL: URL(string: "http://host:8096")!,
            provider: .emby
        )
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":"emby","User":{"Id":"u1","Name":"Alice"}}
        """)

        let session = try await PasswordSignInService(
            server: embyServer,
            deviceID: "dev1",
            http: stub
        ).signIn(username: "alice", password: "pw")

        XCTAssertEqual(session.server.provider, .emby)
        XCTAssertEqual(session.accessToken, "TOK")
    }
}
