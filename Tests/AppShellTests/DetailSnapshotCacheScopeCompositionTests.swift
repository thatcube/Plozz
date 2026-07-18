import XCTest
import CoreModels
import MetadataKit
@testable import AppShell

/// End-to-end check of the E1 wiring: the detail-cache scope `RootView` composes
/// from `HomeRuntimeScope.identityKey` + `accountScopeKey` must change on every
/// effective-content-identity transition (profile, Plex Home-user generation,
/// provider enable/disable, credential rotation, account removal/re-add) and stay
/// stable when nothing changed.
final class DetailSnapshotCacheScopeCompositionTests: XCTestCase {
    /// Mirrors the exact composition performed in `RootView` so this test guards the
    /// real wiring, not a parallel formula.
    private func scope(
        profileID: String,
        plexIdentityGeneration: Int,
        accounts: [Account]
    ) -> DetailSnapshotCacheScope {
        let material = HomeRuntimeScope.identityKey(
            profileID: profileID,
            plexIdentityGeneration: plexIdentityGeneration
        ) + "|" + HomeRuntimeScope.accountScopeKey(accounts)
        return DetailSnapshotCacheScope(profileID: profileID, identityMaterial: material)
    }

    func testProfileSwitchChangesScope() {
        let a = scope(profileID: "alice", plexIdentityGeneration: 0, accounts: [account(id: "a")])
        let b = scope(profileID: "bob", plexIdentityGeneration: 0, accounts: [account(id: "a")])
        XCTAssertNotEqual(a.digest, b.digest)
    }

    func testPlexHomeUserGenerationChangesScope() {
        let owner = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [account(id: "a")])
        let homeUser = scope(profileID: "p", plexIdentityGeneration: 1, accounts: [account(id: "a")])
        XCTAssertNotEqual(owner.digest, homeUser.digest)
    }

    func testEnablingAProviderChangesScope() {
        let single = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [account(id: "a")])
        let paired = scope(
            profileID: "p",
            plexIdentityGeneration: 0,
            accounts: [account(id: "a"), account(id: "b")]
        )
        XCTAssertNotEqual(single.digest, paired.digest)
    }

    func testCredentialRotationChangesScope() {
        let original = account(id: "a")
        var rotated = original
        rotated.credentialRevision = CredentialRevision()
        let before = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [original])
        let after = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [rotated])
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testAccountRemovalAndReAddChangesScope() {
        let original = account(id: "a")
        // Re-add mints a new credential revision even when the id is reused.
        var readded = original
        readded.credentialRevision = CredentialRevision()
        let before = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [original])
        let after = scope(profileID: "p", plexIdentityGeneration: 0, accounts: [readded])
        XCTAssertNotEqual(before.digest, after.digest)
    }

    func testUnchangedIdentityReusesScope() {
        let accounts = [account(id: "a"), account(id: "b")]
        let first = scope(profileID: "p", plexIdentityGeneration: 3, accounts: accounts)
        let second = scope(profileID: "p", plexIdentityGeneration: 3, accounts: accounts.reversed())
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
