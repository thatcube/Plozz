import XCTest
import CoreModels
@testable import AppShell

/// Locks the profile-isolation invariant behind the Home tab's `.id`: the
/// retained ``HomeHeroRuntimeState`` must reset whenever the active profile or the
/// Plex Home-user generation changes, so one profile's watched overlays / curated
/// hero items can never leak into another. The `.id` string is the mechanism, so
/// asserting it changes on those transitions guards the invariant.
final class HomeRuntimeScopeTests: XCTestCase {
    func testIdentityKeyChangesOnProfileSwitch() {
        let alice = HomeRuntimeScope.identityKey(profileID: "alice", plexIdentityGeneration: 0)
        let bob = HomeRuntimeScope.identityKey(profileID: "bob", plexIdentityGeneration: 0)
        XCTAssertNotEqual(alice, bob)
    }

    func testIdentityKeyChangesOnPlexIdentityGenerationBump() {
        let before = HomeRuntimeScope.identityKey(profileID: "alice", plexIdentityGeneration: 0)
        let after = HomeRuntimeScope.identityKey(profileID: "alice", plexIdentityGeneration: 1)
        XCTAssertNotEqual(before, after)
    }

    func testIdentityKeyIsStableForTheSameScope() {
        XCTAssertEqual(
            HomeRuntimeScope.identityKey(profileID: "alice", plexIdentityGeneration: 2),
            HomeRuntimeScope.identityKey(profileID: "alice", plexIdentityGeneration: 2)
        )
    }

    func testAccountScopeChangesWhenAServerIsToggled() {
        XCTAssertNotEqual(
            HomeRuntimeScope.accountScopeKey([account(id: "a")]),
            HomeRuntimeScope.accountScopeKey([account(id: "a"), account(id: "b")])
        )
    }

    func testAccountScopeIsOrderIndependentAndRevisionSensitive() {
        let first = account(id: "a")
        var rotated = first
        rotated.credentialRevision = CredentialRevision()
        let second = account(id: "b")

        XCTAssertEqual(
            HomeRuntimeScope.accountScopeKey([first, second]),
            HomeRuntimeScope.accountScopeKey([second, first])
        )
        XCTAssertNotEqual(
            HomeRuntimeScope.accountScopeKey([first]),
            HomeRuntimeScope.accountScopeKey([rotated])
        )
    }

    private func account(id: String) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "server-\(id)",
                name: id,
                baseURL: URL(string: "https://\(id).example.test")!,
                provider: .jellyfin
            ),
            userID: "user-\(id)",
            userName: id,
            deviceID: "device"
        )
    }
}
