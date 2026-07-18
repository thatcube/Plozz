import XCTest
import CoreModels
import FeatureAuth
import MediaTransportCore
@testable import AppShell

/// End-to-end coverage for the per-profile "Your Servers & Libraries" master
/// server toggle (Settings → ‹Profile›). The toggle flips a server on/off by
/// including/excluding its account(s) in the active profile's set via
/// `AppState.setAccount(_:includedInActiveProfile:)`, and the switch's on/off
/// state is read straight back from `isAccountIncludedInActiveProfile`.
///
/// Regression guard for the bug where turning a server off — especially the
/// **last** remaining server — did nothing: an intentional empty selection was
/// silently re-expanded to "watch every account", so the switch snapped back on.
@MainActor
final class ServerToggleTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ServerToggleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    final class ProviderResolutionContextWiringTests: XCTestCase {
        private final class ContextRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [ProviderResolutionContext] = []

            func append(_ context: ProviderResolutionContext) {
                lock.lock()
                storage.append(context)
                lock.unlock()
            }

            var contexts: [ProviderResolutionContext] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        private final class StubProvider:
            MediaProvider,
            AuthenticatedHTTPOriginProviding,
            @unchecked Sendable
        {
            let kind: ProviderKind
            let session: UserSession
            let authenticatedHTTPOrigin: URL

            init(
                kind: ProviderKind = .mediaShare,
                session: UserSession,
                authenticatedHTTPOrigin: URL? = nil
            ) {
                self.kind = kind
                self.session = session
                self.authenticatedHTTPOrigin =
                    authenticatedHTTPOrigin ?? session.server.baseURL
            }

            func libraries() async throws -> [MediaLibrary] { [] }
            func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
            func latest(limit: Int) async throws -> [MediaItem] { [] }
            func item(id: String) async throws -> MediaItem { throw AppError.notFound }
            func children(of itemID: String) async throws -> [MediaItem] { [] }
            func items(
                in containerID: String,
                kind: MediaItemKind,
                page: PageRequest
            ) async throws -> MediaPage {
                MediaPage(items: [], startIndex: 0, totalCount: 0)
            }
            func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
            func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
                throw AppError.notFound
            }
            func reportPlayback(
                _ progress: PlaybackProgress,
                event: PlaybackEvent
            ) async throws {}
            func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
        }

        private func makeDefaults() -> UserDefaults {
            let suite = "ProviderResolutionContextWiringTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        func testShareResolutionCarriesActiveProfileAndAccountIdentity() throws {
            let secureStore = InMemorySecureStore()
            let vault = MediaCredentialVault(secureStore: secureStore)
            let journal = try CredentialMutationJournal(
                store: DurableLocalStateStore(secureStore: InMemorySecureStore())
            )
            let accountStore = AccountStore(
                secureStore: secureStore,
                mediaCredentialVault: vault,
                credentialJournal: journal
            )
            let account = Account(
                id: "share-account",
                server: MediaServer(
                    id: "share:host/media",
                    name: "Media",
                    baseURL: URL(string: "smb://host/media")!,
                    provider: .mediaShare
                ),
                userID: "guest",
                userName: "",
                deviceID: "device"
            )
            try accountStore.add(account, token: "")

            let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
            let secondProfile = profiles.add(name: "Second")
            let recorder = ContextRecorder()
            let registry = ProviderRegistry()
            registry.register(.mediaShare) { context in
                recorder.append(context)
                return StubProvider(session: context.session)
            }
            let state = AppState(
                accountStore: accountStore,
                registry: registry,
                profilesModel: profiles
            )
            state.bootstrap()

            XCTAssertNotNil(state.accountsProviders.provider(forAccountID: account.id))
            let first = try XCTUnwrap(recorder.contexts.last)
            XCTAssertEqual(first.accountID, account.id)
            XCTAssertEqual(first.credentialRevision, account.credentialRevision)
            XCTAssertEqual(first.localMediaContext?.profileID, profiles.activeProfileID)
            XCTAssertNil(first.localMediaContext?.profileNamespace)

            state.profileFlow.switchProfile(to: secondProfile.id)
            XCTAssertNotNil(state.accountsProviders.provider(forAccountID: account.id))
            let second = try XCTUnwrap(recorder.contexts.last)
            XCTAssertEqual(second.localMediaContext?.profileID, secondProfile.id)
            XCTAssertEqual(second.localMediaContext?.profileNamespace, secondProfile.id)
        }

        func testPlexHomeUserTokenRotatesRuntimeCredentialIdentity() async throws {
            let accountStore = AccountStore(secureStore: InMemorySecureStore())
            let account = Account(
                id: "plex-account",
                server: MediaServer(
                    id: "plex-server",
                    name: "Plex",
                    baseURL: URL(string: "https://plex.example.test:32400")!,
                    provider: .plex
                ),
                userID: "owner",
                userName: "Owner",
                deviceID: "device"
            )
            try accountStore.add(account, token: "owner-token")
            let persistedAccount = try XCTUnwrap(accountStore.loadAccounts().first)
            let recorder = ContextRecorder()
            let registry = ProviderRegistry()
            registry.register(.plex) { context in
                recorder.append(context)
                return StubProvider(
                    kind: .plex,
                    session: context.session,
                    authenticatedHTTPOrigin: URL(
                        string: "https://reachable.plex.test:32400"
                    )!
                )
            }
            let state = AppState(
                accountStore: accountStore,
                registry: registry,
                profilesModel: ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
            )
            state.plexHomeUsers.plexHomeUserSwitch = { homeUserID, _, _, _ in
                "account-token-\(homeUserID)"
            }
            state.plexHomeUsers.plexServerTokenResolve = { _, userToken, _ in
                "server-\(userToken)"
            }
            state.bootstrap()

            XCTAssertNotNil(state.accountsProviders.provider(forAccountID: account.id))
            let ownerContext = try XCTUnwrap(recorder.contexts.last)
            XCTAssertEqual(ownerContext.credentialRevision, persistedAccount.credentialRevision)
            XCTAssertEqual(ownerContext.session.accessToken, "owner-token")

            let firstUser = PlexHomeUser(
                id: "child-a",
                name: "Child A",
                requiresPIN: false
            )
            state.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: account.id, user: firstUser)
            let firstContext = try await waitForPlexContext(
                token: "server-account-token-child-a",
                state: state,
                accountID: account.id,
                recorder: recorder
            )
            XCTAssertNotEqual(
                firstContext.credentialRevision,
                persistedAccount.credentialRevision
            )

            let resource = try AuthenticatedHTTPResource(
                pathBase: .serverRoot,
                path: "/video/:/transcode/universal/start.m3u8"
            )
            let firstLocator = try AuthenticatedHTTPPlaybackLocator(
                provider: .plex,
                accountID: account.id,
                credentialRevision: firstContext.credentialRevision,
                itemID: "item",
                deliveryMode: .serverTranscode,
                resource: resource,
                playSessionID: "plozz-device-item"
            )
            let firstURL = try await state.authenticatedHTTPResolver.resolve(firstLocator)
            XCTAssertEqual(firstURL.host, "reachable.plex.test")
            let firstQuery = URLComponents(
                url: firstURL,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            XCTAssertEqual(
                firstQuery.first { $0.name == "X-Plex-Token" }?.value,
                "server-account-token-child-a"
            )
            XCTAssertEqual(
                firstQuery.first { $0.name == "session" }?.value,
                "plozz-device-item"
            )
            XCTAssertEqual(
                firstQuery.first { $0.name == "X-Plex-Session-Identifier" }?.value,
                "plozz-device-item"
            )

            state.plexHomeUsers.setPlexHomeUserForActiveProfile(
                accountID: account.id,
                user: PlexHomeUser(
                    id: "child-b",
                    name: "Child B",
                    requiresPIN: false
                )
            )
            let secondContext = try await waitForPlexContext(
                token: "server-account-token-child-b",
                state: state,
                accountID: account.id,
                recorder: recorder
            )
            XCTAssertNotEqual(
                secondContext.credentialRevision,
                firstContext.credentialRevision
            )
            do {
                _ = try await state.authenticatedHTTPResolver.resolve(firstLocator)
                XCTFail("stale Plex Home-user locator resolved")
            } catch let error as MediaTransportError {
                XCTAssertEqual(
                    error,
                    .authentication(reason: "inactive authenticated HTTP identity")
                )
            }

            state.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: account.id, user: nil)
            XCTAssertNotNil(state.accountsProviders.provider(forAccountID: account.id))
            let restoredOwner = try XCTUnwrap(recorder.contexts.last)
            XCTAssertEqual(
                restoredOwner.credentialRevision,
                persistedAccount.credentialRevision
            )
            XCTAssertEqual(restoredOwner.session.accessToken, "owner-token")
        }

        private func waitForPlexContext(
            token: String,
            state: AppState,
            accountID: String,
            recorder: ContextRecorder
        ) async throws -> ProviderResolutionContext {
            for _ in 0..<100 {
                _ = state.accountsProviders.provider(forAccountID: accountID)
                if let context = recorder.contexts.last,
                   context.session.accessToken == token {
                    return context
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(
                domain: "ProviderResolutionContextWiringTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for Plex identity token \(token)"
                ]
            )
        }
    }

    private func account(id: String, host: String) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: host,
                baseURL: URL(string: "https://\(host)")!,
                provider: .jellyfin
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    /// Builds an AppState over in-memory stores seeded with the given accounts.
    private func makeAppState(accountIDs: [(String, String)]) throws -> AppState {
        let store = AccountStore(secureStore: InMemorySecureStore())
        for (id, host) in accountIDs {
            try store.add(account(id: id, host: host), token: "token-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let state = AppState(accountStore: store, profilesModel: profiles)
        state.bootstrap()
        return state
    }

    /// A single-server household: turning it off must stick (this is the case
    /// that was completely dead — the toggle could never leave "On").
    func testTurningOffTheOnlyServerSticks() throws {
        let state = try makeAppState(accountIDs: [("a", "a.example.com")])

        // Default: the only account is active, so the server reads "On".
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("a"))

        // Turn it off.
        state.profileFlow.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(
            state.profileFlow.isAccountIncludedInActiveProfile("a"),
            "Turning off the last remaining server must actually turn it off, not snap back on."
        )

        // Turn it back on.
        state.profileFlow.setAccount("a", includedInActiveProfile: true)
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("a"))
    }

    /// The intentional "watch nothing" state must survive a reload (e.g. the
    /// Settings page reappearing / a relaunch), not silently re-expand to all.
    func testEmptySelectionSurvivesReload() throws {
        let state = try makeAppState(accountIDs: [("a", "a.example.com")])
        state.profileFlow.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(state.profileFlow.isAccountIncludedInActiveProfile("a"))

        // A fresh bootstrap (relaunch) must preserve the explicit empty choice.
        state.bootstrap()
        XCTAssertFalse(
            state.profileFlow.isAccountIncludedInActiveProfile("a"),
            "An explicit 'watch nothing' selection must persist across reloads."
        )
    }

    /// A multi-server household: toggling one server off leaves the others on,
    /// and the last one can still be turned off.
    func testTurningServersOffIndependently() throws {
        let state = try makeAppState(accountIDs: [
            ("a", "a.example.com"),
            ("b", "b.example.com")
        ])
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("b"))

        state.profileFlow.setAccount("a", includedInActiveProfile: false)
        XCTAssertFalse(state.profileFlow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("b"))

        // Turning off the now-last server must also stick.
        state.profileFlow.setAccount("b", includedInActiveProfile: false)
        XCTAssertFalse(state.profileFlow.isAccountIncludedInActiveProfile("a"))
        XCTAssertFalse(state.profileFlow.isAccountIncludedInActiveProfile("b"))
    }

    /// A profile may retain ids for accounts that were removed and later
    /// re-added. AppState resolves that stale-only selection to the current
    /// household set; toggling must mutate that resolved set, not the stale raw
    /// value, or removing a visible account becomes a no-op.
    func testTurningOffServerRepairsStaleStoredSelection() throws {
        let accountStore = AccountStore(
            secureStore: InMemorySecureStore()
        )
        try accountStore.add(account(id: "a", host: "a.example.com"), token: "token-a")
        try accountStore.add(account(id: "b", host: "b.example.com"), token: "token-b")

        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        profiles.setActiveAccountIDs(["removed-account"], for: profiles.activeProfileID)

        let state = AppState(accountStore: accountStore, profilesModel: profiles)
        state.bootstrap()
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("b"))

        state.profileFlow.setAccount("a", includedInActiveProfile: false)

        XCTAssertFalse(state.profileFlow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(state.profileFlow.isAccountIncludedInActiveProfile("b"))
        XCTAssertEqual(
            Set(profiles.storedActiveAccountIDs(for: profiles.activeProfileID) ?? []),
            ["b"]
        )
    }

    func testAuthenticatedHTTPResolverUsesFreshAccountAndRejectsOldRevision() async throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account(id: "a", host: "old.example.com"), token: "token-a")
        let initial = try XCTUnwrap(store.loadAccounts().first)
        let state = AppState(
            accountStore: store,
            profilesModel: ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        )
        let resource = try AuthenticatedHTTPResource(
            pathBase: .configuredBaseURL,
            path: "Videos/My%20Movie/stream.mkv",
            queryItems: [
                try AuthenticatedHTTPQueryItem(name: "static", value: "true")
            ]
        )
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin,
            accountID: initial.id,
            credentialRevision: initial.credentialRevision,
            itemID: "item",
            deliveryMode: .directFile,
            resource: resource,
            playSessionID: "play-session"
        )

        let firstURL = try await state.authenticatedHTTPResolver.resolve(locator)
        XCTAssertEqual(firstURL.host, "old.example.com")
        XCTAssertEqual(
            URLComponents(
                url: firstURL,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath,
            "/Videos/My%20Movie/stream.mkv"
        )
        XCTAssertTrue(firstURL.absoluteString.contains("api_key=token-a"))

        try store.add(account(id: "a", host: "new.example.com"), token: "token-a")
        let movedURL = try await state.authenticatedHTTPResolver.resolve(locator)
        XCTAssertEqual(movedURL.host, "new.example.com")

        try store.add(account(id: "a", host: "new.example.com"), token: "token-b")
        do {
            _ = try await state.authenticatedHTTPResolver.resolve(locator)
            XCTFail("stale credential revision resolved")
        } catch let error as MediaTransportError {
            XCTAssertEqual(
                error,
                .authentication(reason: "inactive authenticated HTTP identity")
            )
        }
    }

    func testFailedShareRemovalKeepsLiveScanStatus() {
        let account = Account(
            id: "retained-share",
            server: MediaServer(
                id: "share:retained",
                name: "Retained NAS",
                baseURL: URL(string: "smb://nas.local/media")!,
                provider: .mediaShare
            ),
            userID: "guest",
            userName: "",
            deviceID: "device"
        )
        let store = FailingRemovalAccountStore(account: account)
        let state = AppState(
            accountStore: store,
            profilesModel: ProfilesModel(
                store: ProfileStore(defaults: makeDefaults())
            )
        )
        state.bootstrap()
        state.mediaShare.scanStatus.scanStarted(
            shareID: account.id,
            name: account.server.name
        )

        state.removeAccount(id: account.id)

        XCTAssertTrue(state.accountsProviders.accounts.contains { $0.id == account.id })
        XCTAssertTrue(
            state.mediaShare.scanStatus.state(forShareID: account.id)?.isScanning
                == true
        )
    }
}

private final class FailingRemovalAccountStore:
    AccountPersisting,
    @unchecked Sendable
{
    private let account: Account

    init(account: Account) {
        self.account = account
    }

    func deviceID() -> String { account.deviceID }
    func loadAccounts() -> [Account] { [account] }
    func activeAccountIDs() -> [String] { [account.id] }
    func setActiveAccountIDs(_ ids: [String]) {}
    func token(for accountID: String) -> String? { nil }

    func mediaShareCredential(
        for accountID: String
    ) throws -> MediaShareCredentialEnvelope {
        throw AccountStoreError.mediaShareCredentialInfrastructureUnavailable
    }

    func mediaShareCredential(
        for accountID: String,
        revision: CredentialRevision
    ) throws -> MediaShareCredentialEnvelope {
        throw AccountStoreError.mediaShareCredentialInfrastructureUnavailable
    }

    func add(_ account: Account, token: String) throws {}

    func addMediaShare(
        _ account: Account,
        credential: MediaShareCredentialEnvelope,
        generatedPrivateKey: String?
    ) throws {}

    func remove(id: String) throws {
        throw AccountStoreError.mediaShareCredentialInfrastructureUnavailable
    }

    func clearAll() throws {
        throw AccountStoreError.mediaShareCredentialInfrastructureUnavailable
    }

    func recoverCredentialMutations() throws {}
}
