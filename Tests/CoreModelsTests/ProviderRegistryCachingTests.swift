import XCTest
@testable import CoreModels

final class ProviderRegistryCachingTests: XCTestCase {
    /// Reference-type provider so we can assert instance identity across calls.
    private final class StubProvider: MediaProvider, @unchecked Sendable {
        let kind: ProviderKind = .plex
        let session: UserSession
        init(session: UserSession) { self.session = session }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            MediaPage(items: [], startIndex: 0, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    private func context(
        token: String,
        accountID: String = "account",
        revision: CredentialRevision = CredentialRevision(
            rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        ),
        profileID: String? = nil
    ) -> ProviderResolutionContext {
        let session = UserSession(
            server: MediaServer(
                id: "srv",
                name: "Home",
                baseURL: URL(string: "http://host")!,
                provider: .plex
            ),
            userID: "u",
            userName: "User",
            deviceID: "d",
            accessToken: token
        )
        return ProviderResolutionContext(
            session: session,
            accountID: accountID,
            credentialRevision: revision,
            localMediaContext: profileID.map {
                LocalMediaContext(
                    accountID: accountID,
                    profileID: $0,
                    profileNamespace: $0
                )
            }
        )
    }

    private func session(token: String) -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "http://host")!, provider: .plex),
            userID: "u", userName: "User", deviceID: "d", accessToken: token
        )
    }

    func testSameContextVendsSameInstanceAndBuildsOnce() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { context in
            builds += 1
            return StubProvider(session: context.session)
        }

        let context = context(token: "T")
        let a = try XCTUnwrap(registry.provider(for: context) as? StubProvider)
        let b = try XCTUnwrap(registry.provider(for: context) as? StubProvider)
        let c = try XCTUnwrap(registry.provider(for: context) as? StubProvider)

        XCTAssertTrue(a === b && b === c, "Same session must reuse one provider instance")
        XCTAssertEqual(builds, 1, "Factory must run exactly once for a repeated session")
    }

    func testCredentialRevisionRebuildsAndEvictsStale() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { context in
            builds += 1
            return StubProvider(session: context.session)
        }
        let oldRevision = CredentialRevision(
            rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let newRevision = CredentialRevision(
            rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        let old = try XCTUnwrap(
            registry.provider(for: context(token: "OLD", revision: oldRevision)) as? StubProvider
        )
        let newContext = context(token: "NEW", revision: newRevision)
        let new = try XCTUnwrap(registry.provider(for: newContext) as? StubProvider)
        XCTAssertFalse(old === new, "A refreshed token must build a new provider")
        XCTAssertEqual(builds, 2)

        let newAgain = try XCTUnwrap(registry.provider(for: newContext) as? StubProvider)
        XCTAssertTrue(new === newAgain)
        XCTAssertEqual(builds, 2)
    }

    func testChangedCredentialMaterialRequiresNewRevision() throws {
        let registry = ProviderRegistry()
        registry.register(.plex) { StubProvider(session: $0.session) }
        _ = try registry.provider(for: context(token: "OLD"))

        XCTAssertThrowsError(try registry.provider(for: context(token: "NEW"))) { error in
            XCTAssertEqual(
                error as? ProviderResolutionError,
                .contextChangedWithoutRevision(accountID: "account")
            )
        }
    }

    func testContextDescriptionRedactsCredentialMaterial() {
        let context = context(token: "TOP-SECRET")

        XCTAssertFalse(context.description.contains("TOP-SECRET"))
        XCTAssertTrue(context.description.contains("<redacted>"))
    }

    func testLocalProfilesReceiveIsolatedProviders() throws {
        let registry = ProviderRegistry()
        registry.register(.plex) { StubProvider(session: $0.session) }

        let first = try XCTUnwrap(
            registry.provider(for: context(token: "T", profileID: "profile-a")) as? StubProvider
        )
        let second = try XCTUnwrap(
            registry.provider(for: context(token: "T", profileID: "profile-b")) as? StubProvider
        )

        XCTAssertFalse(first === second)
    }

    func testRejectsMismatchedLocalAccountIdentity() {
        let registry = ProviderRegistry()
        registry.register(.plex) { StubProvider(session: $0.session) }
        let invalid = ProviderResolutionContext(
            session: session(token: "T"),
            accountID: "account",
            credentialRevision: CredentialRevision(),
            localMediaContext: LocalMediaContext(
                accountID: "different-account",
                profileID: "profile",
                profileNamespace: nil
            )
        )

        XCTAssertThrowsError(try registry.provider(for: invalid)) { error in
            XCTAssertEqual(
                error as? ProviderResolutionError,
                .localContextAccountMismatch(
                    accountID: "account",
                    localAccountID: "different-account"
                )
            )
        }
    }

    func testInvalidateCacheForcesRebuild() throws {
        let registry = ProviderRegistry()
        var builds = 0
        registry.register(.plex) { context in
            builds += 1
            return StubProvider(session: context.session)
        }
        let context = context(token: "T")

        _ = try registry.provider(for: context)
        registry.invalidateCache()
        _ = try registry.provider(for: context)
        XCTAssertEqual(builds, 2, "invalidateCache must drop memoized providers")
    }
}
