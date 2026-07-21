import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncSetupCoordinatorTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private func account(_ id: String, url u: String = "https://home.example.com") -> Account {
        let server = MediaServer(id: "srv-\(id)", name: "Home", baseURL: url(u), provider: .jellyfin, connectionURLs: [url(u)])
        return Account(id: id, server: server, userID: "user", userName: "U", deviceID: "src")
    }

    func testExportProducesTokenFreeSnapshot() {
        let snap = SyncSetupCoordinator().exportSnapshot(
            accounts: [account("a1"), account("a2")],
            profiles: [Profile(id: "p1", name: "Brandon")]
        )
        XCTAssertEqual(snap.accounts.count, 2)
        let json = String(data: try! JSONEncoder().encode(snap), encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("password"))
    }

    func testApplyOnFreshDeviceMakesEverythingPending() {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(accounts: [account("a1"), account("a2")], profiles: [Profile(id: "p1", name: "B")])
        let app = coord.apply(snapshot: snap, existingAuthorizations: [:], thisDeviceID: "target")
        XCTAssertEqual(Set(app.pendingAuthorizations.map(\.id)), ["a1", "a2"])
        XCTAssertTrue(app.pendingAuthorizations.allSatisfy { $0.state == .pending && $0.credentialRevision == nil })
    }

    func testMarkingAuthorizedMovesPendingToAuthorized() {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(accounts: [account("a1")], profiles: [])
        let app = coord.apply(snapshot: snap, existingAuthorizations: [:], thisDeviceID: "tv")
        let after = app.markingAuthorized(["a1"], deviceID: "tv", origins: ["a1": ["https://home.example.com"]])
        XCTAssertTrue(after.pendingAuthorizations.isEmpty)
        XCTAssertEqual(after.authorizedAuthorizations.map(\.id), ["a1"])
        XCTAssertEqual(after.authorizedAuthorizations.first?.state, .authorized)
    }

    func testEndpointRetargetIsFlagged() {
        let coord = SyncSetupCoordinator()
        var desc = SyncedAccountDescriptor(id: "a1", provider: .jellyfin, serverID: "s", serverName: "Home",
                                           userID: "u", userName: "U", candidateBaseURLs: [url("https://evil.example.net")])
        desc.recordVersion = 2
        var authed = LocalAuthorization(id: "a1", state: .authorized, deviceID: "tv")
        authed.trustedOrigins = [LocalAuthorization.origin(of: url("https://home.example.com"))]
        let app = coord.apply(snapshot: SyncConfigSnapshot(accounts: [desc]),
                              existingAuthorizations: ["a1": authed], thisDeviceID: "tv")
        XCTAssertEqual(app.needsReverification, ["a1"])
    }
}
