import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

// Test factories that hand each role its pre-wired in-memory link end.
struct StaticHost: PairingLinkHosting {
    let link: PairingLink
    func awaitConnection() async throws -> PairingLink { link }
}
struct StaticGuest: PairingLinkConnecting {
    let link: PairingLink
    func connect() async throws -> PairingLink { link }
}
@MainActor
final class SyncSetupPairingE2ETests: XCTestCase {

    private func account(_ id: String) -> Account {
        let s = MediaServer(id: "s", name: "Home", baseURL: URL(string: "https://h.example.com")!, provider: .jellyfin)
        return Account(id: id, server: s, userID: "u", userName: "U", deviceID: "dev")
    }

    private func service(accounts: [Account] = [], profiles: [Profile] = [],
                         secrets: SyncSecretsBundle = SyncSecretsBundle(),
                         configured: Bool = false, id: String = "dev") -> SyncSetupService {
        let d = UserDefaults(suiteName: "e2e.\(UUID().uuidString)")!
        var flag = SyncSetupFeatureFlag(defaults: d); flag.isEnabled = true
        return SyncSetupService(
            flag: SyncSetupFeatureFlag(defaults: d),
            beaconStore: InMemoryPresenceBeaconStore(),
            deviceID: { id }, deviceName: { "Device" }, isConfigured: { configured },
            configProvider: { .init(accounts: accounts, profiles: profiles) },
            secretsProvider: { secrets }
        )
    }

    func testQRPathTransfersCredentialsNoPending() async throws {
        let (hostLink, guestLink) = await InMemoryPairingLink.makePair()

        let phone = service(
            accounts: [account("a1")], profiles: [Profile(id: "p1", name: "Brandon")],
            secrets: SyncSecretsBundle(accounts: [AccountSecret(accountID: "a1", provider: .jellyfin,
                                                               token: "TOK", deviceID: "phone",
                                                               trustedOrigin: "https://h.example.com")]),
            configured: true, id: "phone")
        let tv = service(configured: false, id: "tv")

        let tvModel = SyncSetupPairingModel(service: tv, makeHostLink: { _ in StaticHost(link: hostLink) })
        let phoneModel = SyncSetupPairingModel(service: phone, makeGuestLink: { _ in StaticGuest(link: guestLink) })

        async let hosting: Void = tvModel.startReceiving()
        // Wait for the TV to advertise; grab the QR invite string.
        var inviteString: String?
        for _ in 0..<2000 {
            if case .waitingForPeer(_, let invite) = tvModel.phase { inviteString = invite.encoded(); break }
            await Task.yield()
        }
        let qr = try XCTUnwrap(inviteString)
        await phoneModel.send(inviteString: qr)
        await hosting

        XCTAssertEqual(phoneModel.phase, .sent)
        guard case .applied(let received) = tvModel.phase else { return XCTFail("phase \(tvModel.phase)") }
        XCTAssertTrue(received.application.pendingAuthorizations.isEmpty)
        XCTAssertEqual(received.application.authorizedAuthorizations.map(\.id), ["a1"])
        XCTAssertEqual(received.config.profiles.map(\.id), ["p1"])
        XCTAssertEqual(received.secrets?.accounts.first?.token, "TOK")
    }

    func testShortCodePathWorksWithoutQR() async throws {
        let (hostLink, guestLink) = await InMemoryPairingLink.makePair()
        let phone = service(accounts: [account("a1")], configured: true, id: "phone")
        let tv = service(configured: false, id: "tv")

        let tvModel = SyncSetupPairingModel(service: tv, makeHostLink: { _ in StaticHost(link: hostLink) })
        let phoneModel = SyncSetupPairingModel(service: phone, makeGuestLink: { _ in StaticGuest(link: guestLink) })

        async let hosting: Void = tvModel.startReceiving()
        var code: String?
        for _ in 0..<2000 {
            if case .waitingForPeer(let c, _) = tvModel.phase { code = c; break }
            await Task.yield()
        }
        let typed = try XCTUnwrap(code)
        // Simulate the user typing the code with spaces/lowercase.
        await phoneModel.send(code: SyncPairingCode.grouped(typed).lowercased())
        await hosting

        XCTAssertEqual(phoneModel.phase, .sent)
        guard case .applied(let received) = tvModel.phase else { return XCTFail("phase \(tvModel.phase)") }
        XCTAssertEqual(received.application.pendingAuthorizations.map(\.id), ["a1"])
    }

    func testMITMKeySubstitutionOnQRPathFails() async throws {
        // The QR carries the phone's EXPECTED key, but the host (attacker) presents
        // a different key over the link -> guest must refuse.
        let (hostLink, guestLink) = await InMemoryPairingLink.makePair()
        let phone = service(accounts: [account("a1")], configured: true, id: "phone")

        // Host sends an invite with an unrelated key.
        let attackerIdentity = SyncPairingIdentity()
        Task {
            let invite = SyncPairingInvite(serviceName: "X", publicKeyData: attackerIdentity.publicKeyData,
                                           context: SyncPairingContext())
            try? await hostLink.send(try JSONEncoder().encode(invite))
        }

        // Guest expects a DIFFERENT key (from the real QR).
        let realKey = SyncPairingIdentity().publicKeyData
        let phoneModel = SyncSetupPairingModel(service: phone, makeGuestLink: { _ in StaticGuest(link: guestLink) })
        // Build a fake QR string carrying realKey + the attacker's service name.
        let fakeInvite = SyncPairingInvite(serviceName: "X", publicKeyData: realKey, context: SyncPairingContext())
        await phoneModel.send(inviteString: fakeInvite.encoded())

        guard case .failed = phoneModel.phase else { return XCTFail("expected failure, got \(phoneModel.phase)") }
    }
}
