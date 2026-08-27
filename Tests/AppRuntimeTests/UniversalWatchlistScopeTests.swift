import XCTest
@testable import AppRuntime

final class UniversalWatchlistScopeTests: XCTestCase {
    /// Token-generation counters are process-local and must never invalidate
    /// last-known ownership persisted across launches.
    func testPersistentScopeDoesNotContainARuntimeGeneration() {
        let firstLaunch = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "plex-account",
            plexIdentityKey: "plex-account#owner"
        )
        let nextLaunch = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "plex-account",
            plexIdentityKey: "plex-account#owner"
        )
        XCTAssertEqual(firstLaunch, nextLaunch)
    }

    /// Live objects capture credentials, so they must rebuild when a token
    /// override changes.
    func testLiveScopeChangesWithIdentityGeneration() {
        let before = UniversalWatchlistScope.live(
            profileID: "profile",
            identityGeneration: 0,
            accountsKey: "plex-account"
        )
        let after = UniversalWatchlistScope.live(
            profileID: "profile",
            identityGeneration: 1,
            accountsKey: "plex-account"
        )
        XCTAssertNotEqual(before, after)
    }

    /// Persisted ownership belongs to a person. A different Home user must not
    /// inherit it, even on the same Plozz profile and Plex server.
    func testPersistentScopeChangesWithPlexHomeUser() {
        let owner = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "plex-account",
            plexIdentityKey: "plex-account#owner"
        )
        let managed = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "plex-account",
            plexIdentityKey: "plex-account#managed-user"
        )
        XCTAssertNotEqual(owner, managed)
    }

    /// Turning a server off retracts its cached contribution on the next launch.
    func testPersistentScopeChangesWithServerSet() {
        let both = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "a,b",
            plexIdentityKey: "a#owner|b#owner"
        )
        let one = UniversalWatchlistScope.persistent(
            profileID: "profile",
            accountsKey: "a",
            plexIdentityKey: "a#owner"
        )
        XCTAssertNotEqual(both, one)
    }
}
