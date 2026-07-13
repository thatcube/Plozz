import XCTest
import CoreModels
import FeatureAuth
@testable import AppShell

/// Regression coverage for media-share account identity.
///
/// A share is identified by its path (host/port/share), not a random UUID, so
/// re-adding the same share — e.g. to update its password — updates the existing
/// account in place instead of forking a duplicate. The bug this guards against:
/// re-adding a share produced two accounts for the same server (one with a stale
/// password), which broke whole-share browsing and playback.
@MainActor
final class MediaShareIdentityTests: XCTestCase {

    // MARK: - Pure identity helper

    func testServerIDIsCaseInsensitiveOnHostAndShare() {
        let a = AppState.mediaShareServerID(host: "NAS", port: nil, share: "Media")
        let b = AppState.mediaShareServerID(host: "nas", port: nil, share: "media")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "share:nas/media")
    }

    func testServerIDIncludesPortWhenPresent() {
        XCTAssertEqual(
            AppState.mediaShareServerID(host: "host", port: 4455, share: "Movies"),
            "share:host:4455/movies"
        )
    }

    func testServerIDDistinguishesDifferentShares() {
        XCTAssertNotEqual(
            AppState.mediaShareServerID(host: "host", port: nil, share: "movies"),
            AppState.mediaShareServerID(host: "host", port: nil, share: "tv")
        )
    }

    // MARK: - End-to-end dedup through AppState

    func testReAddingShareUpdatesInPlaceInsteadOfDuplicating() throws {
        let harness = try makeState()

        harness.state.didConfigureShare(
            host: "192.168.1.10", port: nil, share: "Media",
            username: "COPILOT2", password: "old-pw", displayName: "Media"
        )
        let afterFirst = harness.state.accounts.filter { $0.server.provider == .mediaShare }
        XCTAssertEqual(afterFirst.count, 1)
        let firstRevision = try XCTUnwrap(afterFirst.first).credentialRevision

        // Re-add the SAME share (different username casing + new password) — the
        // "my NAS password changed, let me reconnect" flow.
        harness.state.didConfigureShare(
            host: "192.168.1.10", port: nil, share: "Media",
            username: "Copilot2", password: "new-pw", displayName: "Media"
        )
        let afterSecond = harness.state.accounts.filter { $0.server.provider == .mediaShare }
        XCTAssertEqual(afterSecond.count, 1, "Re-adding a share must not create a duplicate account")

        let updated = try XCTUnwrap(afterSecond.first)
        XCTAssertNotEqual(updated.credentialRevision, firstRevision,
                          "A password change must rotate the credential revision")
        XCTAssertEqual(harness.store.token(for: updated.id), "new-pw")
    }

    func testReAddingIdenticalShareIsANoOpKeepingTheRevision() throws {
        let harness = try makeState()

        harness.state.didConfigureShare(
            host: "host", port: nil, share: "Media",
            username: "user", password: "pw", displayName: "Media"
        )
        let first = try XCTUnwrap(
            harness.state.accounts.first { $0.server.provider == .mediaShare }
        )

        harness.state.didConfigureShare(
            host: "host", port: nil, share: "Media",
            username: "user", password: "pw", displayName: "Media"
        )
        let shares = harness.state.accounts.filter { $0.server.provider == .mediaShare }
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(try XCTUnwrap(shares.first).credentialRevision, first.credentialRevision,
                       "An identical re-add must not rotate the credential revision")
    }

    // MARK: - Harness

    private struct Harness {
        let state: AppState
        let store: AccountStore
    }

    private func makeState() throws -> Harness {
        let secure = InMemorySecureStore()
        let vault = MediaCredentialVault(secureStore: secure)
        let journal = try CredentialMutationJournal(
            store: DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let store = AccountStore(
            secureStore: secure,
            mediaCredentialVault: vault,
            credentialJournal: journal
        )
        let defaults = UserDefaults(suiteName: "MediaShareIdentityTests.\(UUID().uuidString)")!
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let state = AppState(accountStore: store, profilesModel: profiles)
        return Harness(state: state, store: store)
    }
}
