import XCTest
import CoreModels
@testable import FeatureAuth

final class QuickConnectServiceTests: XCTestCase {
    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin)

    private func makeService(
        stub: StubHTTPClient,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> QuickConnectService {
        QuickConnectService(
            server: server,
            deviceID: "dev1",
            http: stub,
            config: .init(pollInterval: 0.01, timeout: 120),
            now: now,
            sleep: { _ in } // don't actually wait in tests
        )
    }

    func testBeginThrowsWhenQuickConnectDisabled() async {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/QuickConnect/Enabled", json: "false")
        let service = makeService(stub: stub)
        do {
            _ = try await service.begin()
            XCTFail("Expected quickConnectUnavailable")
        } catch let error as AppError {
            XCTAssertEqual(error, .quickConnectUnavailable)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testBeginReturnsChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/QuickConnect/Enabled", json: "true")
        stub.stubFixed(pathSuffix: "/QuickConnect/Initiate", json: #"{"Authenticated":false,"Secret":"SEC","Code":"654321"}"#)
        let service = makeService(stub: stub)

        let challenge = try await service.begin()
        XCTAssertEqual(challenge.userCode, "654321")
    }

    func testAwaitApprovalPollsThenAuthenticates() async throws {
        let stub = StubHTTPClient()
        // First poll: not authenticated; second poll: authenticated.
        stub.stubSequence(pathSuffix: "/QuickConnect/Connect", jsons: [
            #"{"Authenticated":false,"Secret":"SEC","Code":"654321"}"#,
            #"{"Authenticated":true,"Secret":"SEC","Code":"654321"}"#
        ])
        stub.stubFixed(pathSuffix: "/Users/AuthenticateWithQuickConnect", json: """
        {"AccessToken":"TOK","ServerId":"srv","User":{"Id":"u1","Name":"Alice"}}
        """)
        let service = makeService(stub: stub)
        let challenge = QuickConnectChallenge(secret: "SEC", userCode: "654321", isAuthenticated: false)

        let session = try await service.awaitApproval(for: challenge)
        XCTAssertEqual(session.accessToken, "TOK")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.userName, "Alice")
        XCTAssertEqual(session.deviceID, "dev1")
        XCTAssertEqual(session.server.id, "srv")
    }

    func testAwaitApprovalTimesOut() async {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/QuickConnect/Connect", json: #"{"Authenticated":false,"Secret":"SEC","Code":"1"}"#)

        // A zero timeout makes the deadline equal to the start time, so the
        // first loop check fails immediately and reports expiry.
        let service = QuickConnectService(
            server: server,
            deviceID: "dev1",
            http: stub,
            config: .init(pollInterval: 0.01, timeout: 0),
            now: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in }
        )
        let challenge = QuickConnectChallenge(secret: "SEC", userCode: "1", isAuthenticated: false)

        do {
            _ = try await service.awaitApproval(for: challenge)
            XCTFail("Expected timeout")
        } catch let error as AppError {
            XCTAssertEqual(error, .quickConnectExpired)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}
