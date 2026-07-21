import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncSetupCoordinatorTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private func account(_ id: String, url u: String = "https://home.example.com") -> Account {
        let server = MediaServer(id: "srv-\(id)", name: "Home", baseURL: url(u), provider: .jellyfin, connectionURLs: [url(u)])
        return Account(id: id, server: server, userID: "user", userName: "U", deviceID: "src")
    }

    func testExportCarriesProfileMembershipsAndRoundTrips() {
        let snap = SyncSetupCoordinator().exportSnapshot(
            accounts: [account("a1"), account("a2")],
            profiles: [Profile(id: "p1", name: "Brandon"), Profile(id: "p2", name: "Kids")],
            profileMemberships: ["p1": ["a1", "a2"], "p2": []]   // subset + explicit-empty
        )
        XCTAssertEqual(snap.profileMemberships["p1"], ["a1", "a2"])
        XCTAssertEqual(snap.profileMemberships["p2"], [])          // empty preserved
        XCTAssertNil(snap.profileMemberships["nope"])              // unset stays absent
        // Survives the wire.
        let data = try! JSONEncoder().encode(snap)
        let back = try! JSONDecoder().decode(SyncConfigSnapshot.self, from: data)
        XCTAssertEqual(back.profileMemberships, snap.profileMemberships)
    }

    func testLegacySnapshotWithoutMembershipsDecodesToEmpty() {
        // A pre-membership sender omits the key entirely; the receiver must not choke.
        let legacy = #"{"accounts":[],"profiles":[],"schemaVersion":1}"#
        let snap = try! JSONDecoder().decode(SyncConfigSnapshot.self, from: Data(legacy.utf8))
        XCTAssertTrue(snap.profileMemberships.isEmpty)
    }

    func testApplyOutcomeClassifiesFailures() {
        typealias O = SyncSetupService.ApplyOutcome
        // Nothing credentialed expected → not a failure (config-only transfer).
        XCTAssertFalse(O(expectedCredentialed: 0, addedCredentialed: 0, failedAccountIDs: [], importedProfiles: 2).isTotalCredentialFailure)
        // Expected some, added none → total failure.
        let total = O(expectedCredentialed: 2, addedCredentialed: 0, failedAccountIDs: ["a1", "a2"], importedProfiles: 1)
        XCTAssertTrue(total.isTotalCredentialFailure)
        XCTAssertFalse(total.isPartialFailure)
        // Added some, one failed → partial (not total).
        let partial = O(expectedCredentialed: 2, addedCredentialed: 1, failedAccountIDs: ["a2"], importedProfiles: 1)
        XCTAssertFalse(partial.isTotalCredentialFailure)
        XCTAssertTrue(partial.isPartialFailure)
        // All added → clean.
        let clean = O(expectedCredentialed: 2, addedCredentialed: 2, failedAccountIDs: [], importedProfiles: 1)
        XCTAssertFalse(clean.isTotalCredentialFailure)
        XCTAssertFalse(clean.isPartialFailure)
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
