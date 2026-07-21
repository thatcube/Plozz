import XCTest
import CryptoKit
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncPairingCryptoTests: XCTestCase {

    private func bundle(withSecrets: Bool = false) -> SyncTransferBundle {
        let config = SyncConfigSnapshot(
            accounts: [SyncedAccountDescriptor(id: "a", provider: .jellyfin, serverID: "s",
                                               serverName: "Home", userID: "u", userName: "U")],
            profiles: [VersionedProfile(profile: Profile(id: "p1", name: "Brandon"))]
        )
        let secrets = withSecrets
            ? SyncSecretsBundle(accounts: [AccountSecret(accountID: "a", provider: .jellyfin,
                                                         token: "SECRET-TOKEN", deviceID: "dev",
                                                         trustedOrigin: "https://home.example.com")])
            : nil
        return SyncTransferBundle(config: config, secrets: secrets)
    }

    func testSealOpenRoundTripsToTargetDevice() throws {
        let tv = SyncPairingIdentity()
        let ctx = SyncPairingContext()
        let b = bundle()
        let sealed = try SyncPairingCrypto.seal(b, toPublicKey: tv.publicKeyData, context: ctx)
        let opened = try SyncPairingCrypto.open(sealed, with: tv)
        XCTAssertEqual(opened, b)
    }

    func testSecretsRoundTripButAreOpaqueOnTheWire() throws {
        let tv = SyncPairingIdentity()
        let b = bundle(withSecrets: true)
        let sealed = try SyncPairingCrypto.seal(b, toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        // On the wire the token is NOT visible (ciphertext is opaque).
        let json = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!
        XCTAssertFalse(json.contains("SECRET-TOKEN"))
        // But the intended device recovers it.
        let opened = try SyncPairingCrypto.open(sealed, with: tv)
        XCTAssertEqual(opened.secrets?.accounts.first?.token, "SECRET-TOKEN")
    }

    func testDifferentDeviceCannotOpen() throws {
        let tv = SyncPairingIdentity()
        let attacker = SyncPairingIdentity()
        let sealed = try SyncPairingCrypto.seal(bundle(withSecrets: true), toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: attacker)) { err in
            XCTAssertEqual(err as? SyncPairingError, .decryptionFailed)
        }
    }

    func testExpiredContextRejected() throws {
        let tv = SyncPairingIdentity()
        let past = Date(timeIntervalSinceNow: -1000)
        let ctx = SyncPairingContext(ttlSeconds: 1, now: past)
        let sealed = try SyncPairingCrypto.seal(bundle(), toPublicKey: tv.publicKeyData, context: ctx)
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: tv)) { err in
            XCTAssertEqual(err as? SyncPairingError, .expiredContext)
        }
    }

    func testReplayIntoDifferentCeremonyFails() throws {
        let tv = SyncPairingIdentity()
        let ctxA = SyncPairingContext()
        let sealed = try SyncPairingCrypto.seal(bundle(), toPublicKey: tv.publicKeyData, context: ctxA)
        // Attacker swaps in a different ceremony context (different info binding).
        var tampered = sealed
        tampered.context = SyncPairingContext()
        XCTAssertThrowsError(try SyncPairingCrypto.open(tampered, with: tv)) { err in
            XCTAssertEqual(err as? SyncPairingError, .decryptionFailed)
        }
    }
}
