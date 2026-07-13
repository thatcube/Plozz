import CoreModels
import FeatureAuth
import Foundation
@testable import AppShell
import XCTest

/// Coverage for WebDAV media-share persistence: identity/dedup, the
/// envelope-based store path (bearer + TLS pin, which the SMB token path can't
/// carry), and the fail-closed URL/credential guards.
@MainActor
final class WebDAVShareOnboardingTests: XCTestCase {

    // MARK: - Identity

    func testWebDAVShareIDIncludesSchemeAndIsCaseSensitiveOnPath() {
        let https = AppState.webDAVShareID(
            scheme: "https", host: "NAS.example.com", port: nil, path: "/DAV/Movies", principal: "anon"
        )
        // Host folds (DNS case-insensitive); scheme + path are preserved.
        XCTAssertEqual(https, "share:https://nas.example.com/DAV/Movies#anon")

        // http vs https are different origins → different identities.
        let http = AppState.webDAVShareID(
            scheme: "http", host: "nas.example.com", port: nil, path: "/DAV/Movies", principal: "anon"
        )
        XCTAssertNotEqual(https, http)

        // Path case matters (WebDAV paths are case-sensitive).
        let lowerPath = AppState.webDAVShareID(
            scheme: "https", host: "nas.example.com", port: nil, path: "/dav/movies", principal: "anon"
        )
        XCTAssertNotEqual(https, lowerPath)
    }

    func testWebDAVShareIDCanonicalizesDefaultPortAndTrailingSlash() {
        // Explicit default port == implicit; trailing slash == no trailing slash.
        let implicit = AppState.webDAVShareID(
            scheme: "https", host: "nas.example.com", port: nil, path: "/dav", principal: "anon"
        )
        let explicit443 = AppState.webDAVShareID(
            scheme: "https", host: "nas.example.com", port: 443, path: "/dav", principal: "anon"
        )
        let trailingSlash = AppState.webDAVShareID(
            scheme: "https", host: "nas.example.com", port: nil, path: "/dav/", principal: "anon"
        )
        XCTAssertEqual(implicit, explicit443, "an explicit default port must dedup with the implicit one")
        XCTAssertEqual(implicit, trailingSlash, "a trailing slash must not fork the account")

        // A non-default port is still distinguished.
        let explicit8443 = AppState.webDAVShareID(
            scheme: "https", host: "nas.example.com", port: 8443, path: "/dav", principal: "anon"
        )
        XCTAssertNotEqual(implicit, explicit8443)
    }

    // MARK: - Persistence through the envelope path

    func testConfiguringBearerWebDAVShareStoresEnvelopeAndDedupes() throws {
        let harness = try makeState()
        let url = URL(string: "https://nas.example.com/dav")!

        harness.state.didConfigureWebDAVShare(
            baseURL: url, auth: .bearer(token: "tok-1"), trustPin: nil, displayName: "DAV"
        )
        let afterFirst = harness.state.accounts.filter { $0.server.provider == .mediaShare }
        XCTAssertEqual(afterFirst.count, 1)
        let account = try XCTUnwrap(afterFirst.first)

        // The credential lives in the vault as a WebDAV bearer envelope — proving
        // the envelope path, not the SMB token path, was used.
        let envelope = try harness.store.mediaShareCredential(for: account.id)
        XCTAssertEqual(envelope.transport, .webDAV)
        guard case .bearer = envelope.authentication else {
            return XCTFail("expected a bearer envelope, got \(envelope.authentication)")
        }
        let firstRevision = account.credentialRevision

        // Re-adding the same URL with a new token replaces in place (one account,
        // rotated revision) — the "my token changed" flow.
        harness.state.didConfigureWebDAVShare(
            baseURL: url, auth: .bearer(token: "tok-2"), trustPin: nil, displayName: "DAV"
        )
        let afterSecond = harness.state.accounts.filter { $0.server.provider == .mediaShare }
        XCTAssertEqual(afterSecond.count, 1, "re-adding the same bearer share must not duplicate")
        XCTAssertNotEqual(try XCTUnwrap(afterSecond.first).credentialRevision, firstRevision)
    }

    func testConfiguringTLSPinnedWebDAVShareStoresTrustMaterial() throws {
        let harness = try makeState()
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xAB, count: 32))

        harness.state.didConfigureWebDAVShare(
            baseURL: URL(string: "https://nas.example.com/dav")!,
            auth: .password(username: "brandon", password: "pw"),
            trustPin: pin,
            displayName: "DAV"
        )
        let account = try XCTUnwrap(
            harness.state.accounts.first { $0.server.provider == .mediaShare }
        )
        let envelope = try harness.store.mediaShareCredential(for: account.id)
        XCTAssertEqual(envelope.trust.tlsLeafCertificateSHA256, pin)
        XCTAssertNotEqual(envelope.trust.revision, UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
                          "a pinned cert must carry a real (non-sentinel) trust revision")
    }

    // MARK: - Fail-closed guards

    func testPasswordOverPlainHTTPIsRejected() throws {
        let harness = try makeState()
        harness.state.didConfigureWebDAVShare(
            baseURL: URL(string: "http://nas.example.com/dav")!,
            auth: .password(username: "u", password: "p"),
            trustPin: nil,
            displayName: "DAV"
        )
        XCTAssertTrue(
            harness.state.accounts.filter { $0.server.provider == .mediaShare }.isEmpty,
            "a reusable credential over cleartext HTTP must be refused"
        )
    }

    func testAnonymousOverPlainHTTPIsAllowed() throws {
        let harness = try makeState()
        harness.state.didConfigureWebDAVShare(
            baseURL: URL(string: "http://nas.example.com/pub")!,
            auth: .anonymous,
            trustPin: nil,
            displayName: "Public"
        )
        XCTAssertEqual(
            harness.state.accounts.filter { $0.server.provider == .mediaShare }.count, 1,
            "anonymous access over plain HTTP is allowed (nothing to leak)"
        )
    }

    func testTLSPinOnPlainHTTPIsRejected() throws {
        let harness = try makeState()
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0x01, count: 32))
        harness.state.didConfigureWebDAVShare(
            baseURL: URL(string: "http://nas.example.com/dav")!,
            auth: .anonymous,
            trustPin: pin,
            displayName: "DAV"
        )
        XCTAssertTrue(harness.state.accounts.filter { $0.server.provider == .mediaShare }.isEmpty,
                      "a certificate pin over plain HTTP is nonsensical and must be refused")
    }

    func testURLWithUserInfoOrQueryIsRejected() throws {
        let harness = try makeState()
        for bad in [
            "https://user:pass@nas.example.com/dav",
            "https://nas.example.com/dav?token=abc",
            "https://nas.example.com/dav#frag",
        ] {
            harness.state.didConfigureWebDAVShare(
                baseURL: URL(string: bad)!, auth: .anonymous, trustPin: nil, displayName: "DAV"
            )
        }
        XCTAssertTrue(harness.state.accounts.filter { $0.server.provider == .mediaShare }.isEmpty,
                      "a base URL with userinfo/query/fragment must be refused")
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
        let defaults = UserDefaults(suiteName: "WebDAVShareOnboardingTests.\(UUID().uuidString)")!
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let state = AppState(accountStore: store, profilesModel: profiles)
        return Harness(state: state, store: store)
    }
}
