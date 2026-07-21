import XCTest
@testable import CoreModels

final class SyncSetupTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Feature flag

    func testFeatureFlagDefaultsOff() {
        let d = UserDefaults(suiteName: "syncsetup.test.\(UUID().uuidString)")!
        let flag = SyncSetupFeatureFlag(defaults: d)
        XCTAssertFalse(flag.isEnabled)
        flag.isEnabled = true
        XCTAssertTrue(SyncSetupFeatureFlag(defaults: d).isEnabled)
    }

    // MARK: Descriptor is token-free and derived correctly

    func testDescriptorFromAccountCarriesNoSecretAndKeepsIdentity() {
        let server = MediaServer(
            id: "srv1", name: "Home", baseURL: url("https://jelly.example.com"),
            provider: .jellyfin, connectionURLs: [url("https://jelly.example.com"), url("http://192.168.1.9:8096")]
        )
        let account = Account(id: "acc1", server: server, userID: "u1", userName: "Brandon", deviceID: "dev-A")
        let desc = SyncedAccountDescriptor(account: account)

        XCTAssertEqual(desc.id, "acc1")
        XCTAssertEqual(desc.provider, .jellyfin)
        XCTAssertEqual(desc.serverID, "srv1")
        XCTAssertEqual(desc.userName, "Brandon")
        XCTAssertEqual(desc.candidateBaseURLs.count, 2)
        // Round-trips as Codable without any token field existing.
        let data = try! JSONEncoder().encode(desc)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("password"))
        XCTAssertFalse(json.lowercased().contains("deviceid"))
    }

    // MARK: Endpoint-retarget protection

    func testAuthorizedDeviceWithholdsUntrustedOrigin() {
        var auth = LocalAuthorization(id: "acc1", state: .authorized, deviceID: "dev-A")
        auth.trustedOrigins = [LocalAuthorization.origin(of: url("https://jelly.example.com"))]

        // A synced descriptor tries to introduce an attacker origin.
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .jellyfin, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://jelly.example.com"), url("https://evil.example.net")]
        )

        // Only the already-trusted origin is usable; the new one is withheld.
        let allowed = auth.allowedURLs(from: desc)
        XCTAssertEqual(allowed, [url("https://jelly.example.com")])
        XCTAssertTrue(auth.requiresReverification(for: desc))
    }

    func testPendingDeviceMayUseAllCandidatesForFreshSignIn() {
        let auth = LocalAuthorization(id: "acc1", state: .pending, deviceID: "dev-B")
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .plex, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://plex.example.com"), url("http://10.0.0.5:32400")]
        )
        XCTAssertEqual(auth.allowedURLs(from: desc).count, 2)
        XCTAssertFalse(auth.requiresReverification(for: desc))
    }

    func testAuthorizedDeviceWithMatchingOriginsNeedsNoReverification() {
        var auth = LocalAuthorization(id: "acc1", state: .authorized, deviceID: "dev-A")
        auth.trustedOrigins = [
            LocalAuthorization.origin(of: url("https://jelly.example.com")),
            LocalAuthorization.origin(of: url("http://192.168.1.9:8096"))
        ]
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .jellyfin, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://jelly.example.com"), url("http://192.168.1.9:8096")]
        )
        XCTAssertFalse(auth.requiresReverification(for: desc))
        XCTAssertEqual(auth.allowedURLs(from: desc).count, 2)
    }

    func testOriginNormalizationIgnoresPathAndCase() {
        XCTAssertEqual(
            LocalAuthorization.origin(of: url("HTTPS://Jelly.Example.com/web/index.html")),
            "https://jelly.example.com"
        )
        XCTAssertEqual(
            LocalAuthorization.origin(of: url("http://10.0.0.5:32400/library")),
            "http://10.0.0.5:32400"
        )
    }
}
