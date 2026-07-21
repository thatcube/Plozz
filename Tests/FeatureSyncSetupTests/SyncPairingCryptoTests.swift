import XCTest
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
        let b = bundle()
        let sealed = try SyncPairingCrypto.seal(b, toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        XCTAssertEqual(try SyncPairingCrypto.open(sealed, with: tv), b)
    }

    func testSecretsRoundTripButOpaqueOnWire() throws {
        let tv = SyncPairingIdentity()
        let sealed = try SyncPairingCrypto.seal(bundle(withSecrets: true), toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        let json = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!
        XCTAssertFalse(json.contains("SECRET-TOKEN"))
        XCTAssertEqual(try SyncPairingCrypto.open(sealed, with: tv).secrets?.accounts.first?.token, "SECRET-TOKEN")
    }

    func testDifferentDeviceCannotOpen() throws {
        let tv = SyncPairingIdentity(); let attacker = SyncPairingIdentity()
        let sealed = try SyncPairingCrypto.seal(bundle(withSecrets: true), toPublicKey: tv.publicKeyData, context: SyncPairingContext())
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: attacker)) {
            XCTAssertEqual($0 as? SyncPairingError, .decryptionFailed)
        }
    }

    func testExpiredContextRejected() throws {
        let tv = SyncPairingIdentity()
        let sealed = try SyncPairingCrypto.seal(bundle(), toPublicKey: tv.publicKeyData,
                                                context: SyncPairingContext(ttlSeconds: 1, now: Date(timeIntervalSinceNow: -1000)))
        XCTAssertThrowsError(try SyncPairingCrypto.open(sealed, with: tv)) {
            XCTAssertEqual($0 as? SyncPairingError, .expiredContext)
        }
    }

    // MARK: Short code

    func testShortCodeNormalizeAndGroup() {
        XCTAssertEqual(SyncPairingCode.normalize("7k2q 9f"), "7K2Q9F")
        XCTAssertEqual(SyncPairingCode.normalize("il-o1"), "1101")
        XCTAssertEqual(SyncPairingCode.grouped("7K2Q9F"), "7K2Q-9F")
    }

    func testGeneratedCodeAvoidsAmbiguousLetters() {
        for _ in 0..<50 {
            let code = SyncPairingCode.generate()
            XCTAssertEqual(code.count, 4)
            XCTAssertFalse(code.contains(where: { "ILOU01".contains($0) }))
        }
    }
}
