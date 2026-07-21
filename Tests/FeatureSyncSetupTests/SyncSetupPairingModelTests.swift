import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

@MainActor
final class SyncSetupPairingModelTests: XCTestCase {

    private func service(accounts: [Account] = [], profiles: [Profile] = [], configured: Bool = false) -> SyncSetupService {
        let d = UserDefaults(suiteName: "pm.\(UUID().uuidString)")!
        var flag = SyncSetupFeatureFlag(defaults: d); flag.isEnabled = true
        return SyncSetupService(
            flag: SyncSetupFeatureFlag(defaults: d),
            beaconStore: InMemoryPresenceBeaconStore(),
            deviceID: { "dev" },
            deviceName: { "Device" },
            isConfigured: { configured },
            configProvider: { .init(accounts: accounts, profiles: profiles) }
        )
    }

    private func account(_ id: String) -> Account {
        let s = MediaServer(id: "s", name: "Home", baseURL: URL(string: "https://h.example.com")!, provider: .jellyfin)
        return Account(id: id, server: s, userID: "u", userName: "U", deviceID: "dev")
    }

    func testEndToEndPairingBetweenTwoModels() async throws {
        let channel = InMemoryPairingChannel()

        // TV (fresh) receives over the shared channel.
        let tv = SyncSetupPairingModel(
            service: service(configured: false),
            makeReceiver: { _ in channel }
        )
        // Phone (has config) sends over the same channel.
        let phone = SyncSetupPairingModel(
            service: service(accounts: [account("a1")], profiles: [Profile(id: "p1", name: "Brandon")], configured: true),
            makeSender: { _ in channel }
        )

        async let receiving: Void = tv.startReceiving()

        // Wait for the TV to advertise its invite.
        var invite: SyncPairingInvite?
        for _ in 0..<1000 {
            if case .waitingForPhone(let i) = tv.phase { invite = i; break }
            await Task.yield()
        }
        let unwrapped = try XCTUnwrap(invite)

        await phone.send(to: unwrapped)
        await receiving

        XCTAssertEqual(phone.phase, .sent)
        guard case .applied(let application) = tv.phase else {
            return XCTFail("expected applied, got \(tv.phase)")
        }
        XCTAssertEqual(application.profiles.map(\.id), ["p1"])
        XCTAssertEqual(application.pendingAuthorizations.map(\.id), ["a1"])
    }

    func testSendRejectsGarbageInvite() async {
        let phone = SyncSetupPairingModel(service: service())
        await phone.send(inviteString: "not-a-code")
        guard case .failed = phone.phase else { return XCTFail("expected failed") }
    }
}
