import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

// Test factories that hand each role its pre-wired in-memory link end.
final class StaticHost: PairingLinkHosting {
    let link: PairingLink
    init(link: PairingLink) { self.link = link }
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

    func testShortCodePathRunsSASAndTransfers() async throws {
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

        // Sender begins; the non-QR path must surface a SAS to confirm.
        async let sending: Void = phoneModel.send(code: SyncPairingCode.grouped(typed).lowercased())
        var sas: String?
        for _ in 0..<4000 {
            if case .confirmingSAS(let c) = phoneModel.phase { sas = c; break }
            await Task.yield()
        }
        let phoneSAS = try XCTUnwrap(sas)
        // Both devices must derive the SAME code when there is no MITM.
        for _ in 0..<2000 where tvModel.hostSASCode == nil { await Task.yield() }
        XCTAssertEqual(tvModel.hostSASCode, phoneSAS)

        // User confirms the match → credentials flow.
        phoneModel.confirmSASMatch(true)
        await sending
        await hosting

        XCTAssertEqual(phoneModel.phase, .sent)
        guard case .applied(let received) = tvModel.phase else { return XCTFail("phase \(tvModel.phase)") }
        XCTAssertEqual(received.application.pendingAuthorizations.map(\.id), ["a1"])
    }

    func testSASRejectionAbortsSend() async throws {
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

        async let sending: Void = phoneModel.send(code: typed)
        for _ in 0..<4000 {
            if case .confirmingSAS = phoneModel.phase { break }
            await Task.yield()
        }
        // User says the codes DON'T match → send must abort, no credentials sent.
        phoneModel.confirmSASMatch(false)
        await sending
        tvModel.stopReceiving()
        await hosting

        guard case .failed = phoneModel.phase else { return XCTFail("expected failure, got \(phoneModel.phase)") }
    }

    func testMITMKeySubstitutionOnQRPathFails() async throws {
        // The QR pins the phone's EXPECTED key, but the host (attacker) presents a
        // different key over the link -> guest must refuse before sending anything.
        let (hostLink, guestLink) = await InMemoryPairingLink.makePair()
        let phone = service(accounts: [account("a1")], configured: true, id: "phone")

        // Attacker plays host: consume the guest's hello, then send a handshake
        // invite carrying the attacker's (wrong) key.
        let attackerIdentity = SyncPairingIdentity()
        Task {
            _ = try? await hostLink.receive() // guest hello
            let invite = PairingHandshakeInvite(
                publicKeyData: attackerIdentity.publicKeyData,
                context: SyncPairingContext(),
                hostNonce: SyncPairingSAS.makeNonce()
            )
            try? await hostLink.send(try JSONEncoder().encode(invite))
        }

        let realKey = SyncPairingIdentity().publicKeyData
        let phoneModel = SyncSetupPairingModel(service: phone, makeGuestLink: { _ in StaticGuest(link: guestLink) })
        let fakeInvite = SyncPairingInvite(serviceName: "X", publicKeyData: realKey, context: SyncPairingContext())
        await phoneModel.send(inviteString: fakeInvite.encoded())

        guard case .failed = phoneModel.phase else { return XCTFail("expected failure, got \(phoneModel.phase)") }
    }
}
