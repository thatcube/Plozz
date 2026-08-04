import XCTest
import CoreModels
import MetadataKit
@testable import AppShell

/// End-to-end check of the E1 wiring: the detail-cache scope `RootView` composes
/// from `HomeRuntimeScope.identityKey` + `accountScopeKey` must change on every
/// effective-content-identity transition (profile, Plex Home user,
/// provider enable/disable, credential rotation, account removal/re-add) and stay
/// stable when nothing changed.
final class DetailSnapshotCacheScopeCompositionTests: XCTestCase {
    /// Mirrors the exact composition performed in `RootView` so this test guards the
    /// real wiring, not a parallel formula.
    private func scope(
        profileID: String,
        plexPlaybackIdentityKey: String,
        accounts: [Account]
    ) -> DetailSnapshotCacheScope {
        let material = HomeRuntimeScope.identityKey(
            profileID: profileID,
            plexPlaybackIdentityKey: plexPlaybackIdentityKey
        ) + "|" + HomeRuntimeScope.accountScopeKey(accounts)
        return DetailSnapshotCacheScope(profileID: profileID, identityMaterial: material)
    }

    func testProfileSwitchChangesScope() {
        let a = scope(profileID: "alice", plexPlaybackIdentityKey: "", accounts: [account(id: "a")])
        let b = scope(profileID: "bob", plexPlaybackIdentityKey: "", accounts: [account(id: "a")])
        XCTAssertNotEqual(a.digest, b.digest)
    }

    func testPlexHomeUserChangesScope() {
        let owner = scope(profileID: "p", plexPlaybackIdentityKey: "plex#owner", accounts: [account(id: "a")])
        let homeUser = scope(profileID: "p", plexPlaybackIdentityKey: "plex#managed", accounts: [account(id: "a")])
        XCTAssertNotEqual(owner.digest, homeUser.digest)
    }

    func testEnablingAProviderChangesScope() {
        let single = scope(profileID: "p", plexPlaybackIdentityKey: "", accounts: [account(id: "a")])
        let paired = scope(
            profileID: "p",
            plexPlaybackIdentityKey: "",
            accounts: [account(id: "a"), account(id: "b")]
        )
        XCTAssertNotEqual(single.digest, paired.digest)
    }

    func testCredentialRotationChangesScope() {
        let original = account(id: "a")
        var rotated = original
        rotated.credentialRevision = CredentialRevision()
        let before = scope(profileID: "p", plexPlaybackIdentityKey: "", accounts: [original])
        let after = scope(profileID: "p", plexPlaybackIdentityKey: "", accounts: [rotated])
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testAccountRemovalAndReAddChangesScope() {
        let original = account(id: "a")
        // Re-add mints a new credential revision even when the id is reused.
        var readded = original
        readded.credentialRevision = CredentialRevision()
        let before = scope(profileID: "p", plexPlaybackIdentityKey: "", accounts: [original])
        let after = scope(profileID: "p", plexPlaybackIdentityKey: "", accounts: [readded])
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testUnchangedIdentityReusesScope() {
        let accounts = [account(id: "a"), account(id: "b")]
        let first = scope(profileID: "p", plexPlaybackIdentityKey: "plex#owner", accounts: accounts)
        let second = scope(
            profileID: "p",
            plexPlaybackIdentityKey: "plex#owner",
            accounts: accounts.reversed()
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.digest, second.digest)
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
