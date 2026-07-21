import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncSetupCoordinatorTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func account(_ id: String, provider: ProviderKind = .jellyfin, url u: String = "https://home.example.com") -> Account {
        let server = MediaServer(id: "srv-\(id)", name: "Home", baseURL: url(u), provider: provider, connectionURLs: [url(u)])
        return Account(id: id, server: server, userID: "user", userName: "U", deviceID: "src-device")
    }

    func testExportProducesTokenFreeSnapshot() {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(
            accounts: [account("a1"), account("a2", provider: .plex)],
            profiles: [Profile(id: "p1", name: "Brandon")]
        )
        XCTAssertEqual(snap.accounts.count, 2)
        XCTAssertEqual(snap.profiles.count, 1)
        let json = String(data: try! JSONEncoder().encode(snap), encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("password"))
    }

    func testApplyOnFreshDeviceMakesEverythingPending() {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(accounts: [account("a1"), account("a2")], profiles: [Profile(id: "p1", name: "Brandon")])
        let app = coord.apply(snapshot: snap, existingAuthorizations: [:], thisDeviceID: "target-device")

        XCTAssertEqual(app.profiles.map(\.id), ["p1"])
        XCTAssertEqual(Set(app.pendingAuthorizations.map(\.id)), ["a1", "a2"])
        XCTAssertTrue(app.pendingAuthorizations.allSatisfy { $0.state == .pending && $0.deviceID == "target-device" })
        XCTAssertTrue(app.needsReverification.isEmpty)
        // Crucially: applying never yields an authorized/credentialed account.
        XCTAssertTrue(app.pendingAuthorizations.allSatisfy { $0.credentialRevision == nil })
    }

    func testAlreadyAuthorizedAccountIsNotRePended() {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(accounts: [account("a1")], profiles: [])
        var authed = LocalAuthorization(id: "a1", state: .authorized, deviceID: "target-device")
        authed.trustedOrigins = [LocalAuthorization.origin(of: url("https://home.example.com"))]

        let app = coord.apply(snapshot: snap, existingAuthorizations: ["a1": authed], thisDeviceID: "target-device")
        XCTAssertTrue(app.pendingAuthorizations.isEmpty)
        XCTAssertTrue(app.needsReverification.isEmpty)
    }

    func testEndpointRetargetIsFlaggedNotApplied() {
        let coord = SyncSetupCoordinator()
        // Snapshot points a1 at an attacker origin the device doesn't trust.
        var desc = SyncedAccountDescriptor(id: "a1", provider: .jellyfin, serverID: "s", serverName: "Home",
                                           userID: "u", userName: "U",
                                           candidateBaseURLs: [url("https://evil.example.net")])
        desc.recordVersion = 2
        let snap = SyncConfigSnapshot(accounts: [desc])

        var authed = LocalAuthorization(id: "a1", state: .authorized, deviceID: "target-device")
        authed.trustedOrigins = [LocalAuthorization.origin(of: url("https://home.example.com"))]

        let app = coord.apply(snapshot: snap, existingAuthorizations: ["a1": authed], thisDeviceID: "target-device")
        XCTAssertEqual(app.needsReverification, ["a1"])
        XCTAssertTrue(app.pendingAuthorizations.isEmpty)
    }

    func testRoundTripThroughSealedPayload() throws {
        let coord = SyncSetupCoordinator()
        let snap = coord.exportSnapshot(accounts: [account("a1")], profiles: [Profile(id: "p1", name: "Brandon")])
        let tv = SyncPairingIdentity()
        let ctx = SyncPairingContext()
        let sealed = try SyncPairingCrypto.seal(SyncTransferBundle(config: snap), toPublicKey: tv.publicKeyData, context: ctx)
        let received = try SyncPairingCrypto.open(sealed, with: tv)
        let app = coord.apply(snapshot: received.config, existingAuthorizations: [:], thisDeviceID: "tv-device")
        XCTAssertEqual(app.pendingAuthorizations.map(\.id), ["a1"])
        XCTAssertEqual(app.profiles.map(\.id), ["p1"])
    }
}
