import XCTest
import CryptoKit
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncPairingCryptoTests: XCTestCase {

    private func snapshot() -> SyncConfigSnapshot {
        SyncConfigSnapshot(
            accounts: [SyncedAccountDescriptor(id: "a", provider: .jellyfin, serverID: "s",
                                               serverName: "Home", userID: "u", userName: "U")],
            profiles: [VersionedProfile(profile: Profile(id: "p1", name: "Brandon"))]
        )
    }

    func testSealOpenRoundTripsToTargetDevice() throws {
        let tv = SyncPairingIdentity()
        let ctx = SyncPairingContext()
        let snap = snapshot()
        let sealed = try SyncPairingCrypto.seal(snap, toPublicKey: tv.publicKeyData, context: ctx)
        let opened = try SyncPairingCrypto.open(sealed, with: tv)
        XCTAssertEqual(opened, snap)
        // The sealed blob is opaque + carries no token/password.
        let json = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("password"))
    }

    func testDifferentDeviceCannotOpen() throws {
        let tv = SyncPairingIdentity()
        let attacker = SyncPairingIdentity()
        let sealed = try SyncPairingCrypto.seal(snapshot(), toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: attacker)) { err in
            XCTAssertEqual(err as? SyncPairingError, .decryptionFailed)
        }
    }

    func testExpiredContextRejected() throws {
        let tv = SyncPairingIdentity()
        let past = Date(timeIntervalSinceNow: -1000)
        let ctx = SyncPairingContext(ttlSeconds: 1, now: past)
        let sealed = try SyncPairingCrypto.seal(snapshot(), toPublicKey: tv.publicKeyData, context: ctx)
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: tv)) { err in
            XCTAssertEqual(err as? SyncPairingError, .expiredContext)
        }
    }

    func testReplayIntoDifferentCeremonyFails() throws {
        let tv = SyncPairingIdentity()
        let ctxA = SyncPairingContext()
        let sealed = try SyncPairingCrypto.seal(snapshot(), toPublicKey: tv.publicKeyData, context: ctxA)
        // Attacker swaps in a different ceremony context (different info binding).
        var tampered = sealed
        tampered.context = SyncPairingContext()
        XCTAssertThrowsError(try SyncPairingCrypto.open(tampered, with: tv)) { err in
            XCTAssertEqual(err as? SyncPairingError, .decryptionFailed)
        }
    }
}
