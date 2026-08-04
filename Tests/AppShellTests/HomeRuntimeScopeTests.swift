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

    // MARK: - homeScopeKey (the Home/Search subtree identity)

    /// The regression this exists for: two profiles sharing the same servers
    /// produced an identical `accountScopeKey`, so SwiftUI kept the Home subtree
    /// and its cached view model went on serving the previous profile's rows —
    /// the watchlist most visibly. The key must move when the profile does, even
    /// when nothing about the accounts has.
    func testHomeScopeKeyChangesOnProfileSwitchWithIdenticalAccounts() {
        let accounts = [account(id: "a"), account(id: "b")]
        let alice = HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: accounts)
        let bob = HomeRuntimeScope.homeScopeKey(profileID: "bob", accounts: accounts)
        XCTAssertNotEqual(alice, bob)
    }

    func testHomeScopeKeyStillChangesWhenAccountsChange() {
        let before = HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: [account(id: "a")])
        let after = HomeRuntimeScope.homeScopeKey(
            profileID: "alice",
            accounts: [account(id: "a"), account(id: "b")]
        )
        XCTAssertNotEqual(before, after)
    }

    /// Stable for an unchanged profile + account set: the key is a SwiftUI `.id`,
    /// so a spurious change tears down and rebuilds Home and Search.
    func testHomeScopeKeyIsStableForTheSameInputs() {
        let accounts = [account(id: "a"), account(id: "b")]
        XCTAssertEqual(
            HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: accounts),
            HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: accounts)
        )
    }

    /// Account ORDER is not identity — the underlying key sorts — so a reshuffled
    /// list must not rebuild the world.
    func testHomeScopeKeyIgnoresAccountOrder() {
        let accounts = [account(id: "a"), account(id: "b")]
        XCTAssertEqual(
            HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: accounts),
            HomeRuntimeScope.homeScopeKey(profileID: "alice", accounts: accounts.reversed())
        )
    }

}
