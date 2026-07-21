import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncPairingChannelTests: XCTestCase {

    func testInviteEncodesAndDecodesRoundTrip() {
        let id = SyncPairingIdentity()
        let invite = SyncPairingInvite(serviceName: "BrandoTV",
                                       publicKeyData: id.publicKeyData,
                                       context: SyncPairingContext())
        let string = invite.encoded()
        XCTAssertTrue(string.hasPrefix("plozz-pair://"))
        let decoded = SyncPairingInvite.decode(string)
        XCTAssertEqual(decoded, invite)
    }

    func testInviteDecodeRejectsGarbage() {
        XCTAssertNil(SyncPairingInvite.decode("https://example.com"))
        XCTAssertNil(SyncPairingInvite.decode("plozz-pair://!!!not-base64!!!"))
    }

    func testEndToEndPairingOverInMemoryChannel() async throws {
        // TV creates identity + invite (shown as QR).
        let tvIdentity = SyncPairingIdentity()
        let invite = SyncPairingInvite(serviceName: "BrandoTV",
                                       publicKeyData: tvIdentity.publicKeyData,
                                       context: SyncPairingContext())

        // Phone builds a non-secret snapshot and sends it to the invite.
        let coord = SyncSetupCoordinator()
        let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "https://home.example.com")!,
                                 provider: .jellyfin, connectionURLs: [URL(string: "https://home.example.com")!])
        let account = Account(id: "a1", server: server, userID: "u", userName: "U", deviceID: "phone")
        let snapshot = coord.exportSnapshot(accounts: [account], profiles: [Profile(id: "p1", name: "Brandon")])

        let channel = InMemoryPairingChannel()
        try await SyncPairingSession.sendSetup(SyncTransferBundle(config: snapshot), to: invite, over: channel)

        // TV receives + opens + applies.
        let received = try await SyncPairingSession.receiveSetup(with: tvIdentity, over: channel)
        let app = coord.apply(snapshot: received.config, existingAuthorizations: [:], thisDeviceID: "tv")

        XCTAssertEqual(app.profiles.map(\.id), ["p1"])
        XCTAssertEqual(app.pendingAuthorizations.map(\.id), ["a1"])
        XCTAssertTrue(app.pendingAuthorizations.allSatisfy { $0.state == .pending })
    }

    func testExpiredInviteIsRejectedBeforeSending() async throws {
        let tvIdentity = SyncPairingIdentity()
        let past = Date(timeIntervalSinceNow: -1000)
        let invite = SyncPairingInvite(serviceName: "BrandoTV",
                                       publicKeyData: tvIdentity.publicKeyData,
                                       context: SyncPairingContext(ttlSeconds: 1, now: past))
        let channel = InMemoryPairingChannel()
        do {
            try await SyncPairingSession.sendSetup(SyncTransferBundle(config: SyncConfigSnapshot()), to: invite, over: channel)
            XCTFail("expected expiredContext")
        } catch {
            XCTAssertEqual(error as? SyncPairingError, .expiredContext)
        }
    }
}
