import XCTest
import CoreModels
@testable import FeatureAuthCore

final class SessionStateMachineTests: XCTestCase {
    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin)
    private func account(_ id: String = "a1") -> Account {
        Account(id: id, server: server, userID: "u", userName: "A", deviceID: "d")
    }

    func testLaunchWithAccountsBecomesReady() {
        var m = SessionStateMachine()
        m.apply(.restored([account()]))
        XCTAssertEqual(m.state, .ready)
    }

    func testLaunchWithoutAccountsStartsOnboarding() {
        var m = SessionStateMachine()
        m.apply(.restored([]))
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: false))
    }

    func testFirstRunHappyPath() {
        var m = SessionStateMachine()
        m.apply(.restored([]))
        m.apply(.serverSelected(server))
        XCTAssertEqual(m.state, .onboarding(.authenticating(server), canReturnToApp: false))
        m.apply(.accountAuthenticated)
        XCTAssertEqual(m.state, .ready)
    }

    func testAddSecondAccountLoopReturnsToReady() {
        var m = SessionStateMachine(state: .ready)
        m.apply(.addAccountRequested)
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: true))
        m.apply(.serverSelected(server))
        XCTAssertEqual(m.state, .onboarding(.authenticating(server), canReturnToApp: true))
        m.apply(.accountAuthenticated)
        XCTAssertEqual(m.state, .ready)
    }

    func testFirstRunAuthDetoursThroughProfileSetup() {
        // First-ever account: auth success routes into the profile-setup
        // sub-flow (enable-profiles prompt → confirm → theme picker), not
        // straight to the app.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: false))
        m.apply(.accountAuthenticatedNeedsProfile)
        XCTAssertEqual(m.state, .onboarding(.enableProfilesPrompt, canReturnToApp: true))
        m.apply(.profilesEnabled)
        XCTAssertEqual(m.state, .onboarding(.confirmProfile, canReturnToApp: true))
        m.apply(.profileConfirmed)
        XCTAssertEqual(m.state, .onboarding(.selectTheme, canReturnToApp: true))
        m.apply(.themeSelected)
        XCTAssertEqual(m.state, .ready)
    }

    func testFirstRunDeclineProfilesStillShowsThemePicker() {
        // "Not Now — Just Me" on the enable-profiles prompt skips the confirm
        // screen but still stops at the one-time theme picker before the app.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: false))
        m.apply(.accountAuthenticatedNeedsProfile)
        XCTAssertEqual(m.state, .onboarding(.enableProfilesPrompt, canReturnToApp: true))
        m.apply(.profilesDeclined)
        XCTAssertEqual(m.state, .onboarding(.selectTheme, canReturnToApp: true))
        m.apply(.themeSelected)
        XCTAssertEqual(m.state, .ready)
    }

    func testPlexUserSelectionThenFirstRunProfileSetup() {
        // Plex with 2+ Home users on first run: pick the Plex user, then enter
        // the profile-setup sub-flow.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: false))
        m.apply(.plexUserSelectionRequired)
        XCTAssertEqual(m.state, .onboarding(.selectPlexUser, canReturnToApp: true))
        m.apply(.accountAuthenticatedNeedsProfile)
        XCTAssertEqual(m.state, .onboarding(.enableProfilesPrompt, canReturnToApp: true))
    }

    func testPlexUserSelectionCanResolveDirectlyFromProviderPicker() {
        var m = SessionStateMachine(
            state: .onboarding(.selectingServer, canReturnToApp: false)
        )

        m.apply(.plexUserSelectionRequired)

        XCTAssertEqual(m.state, .onboarding(.selectPlexUser, canReturnToApp: true))
    }

    func testPlexLibrarySelectionCanResolveDirectlyFromProviderPicker() {
        var m = SessionStateMachine(
            state: .onboarding(.selectingServer, canReturnToApp: false)
        )

        m.apply(.librarySelectionRequired)

        XCTAssertEqual(m.state, .onboarding(.selectLibraries, canReturnToApp: true))
    }

    func testPlexUserSelectionOnLaterAddReturnsToApp() {
        // Plex with 2+ Home users added later (not first run): pick the user,
        // then straight back to the app — no profile-setup detour.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: true))
        m.apply(.plexUserSelectionRequired)
        XCTAssertEqual(m.state, .onboarding(.selectPlexUser, canReturnToApp: true))
        m.apply(.accountAuthenticated)
        XCTAssertEqual(m.state, .ready)
    }

    func testAddAnotherAccountNeverShowsProfileSetup() {
        // Adding a server later uses the plain `.accountAuthenticated` event and
        // must not detour through the profile-setup sub-flow.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: true))
        m.apply(.accountAuthenticated)
        XCTAssertEqual(m.state, .ready)
    }

    func testCancelAddingAnotherAccountReturnsToApp() {
        var m = SessionStateMachine(state: .onboarding(.selectingServer, canReturnToApp: true))
        m.apply(.cancelOnboarding)
        XCTAssertEqual(m.state, .ready)
    }

    func testCancelFirstRunOnboardingStaysOnPicker() {
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: false))
        m.apply(.cancelOnboarding)
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: false))
    }

    func testCancelQuickConnectWhenAddingReturnsToPickerNotApp() {
        // Cancelling the Quick Connect step while adding another account steps
        // back to the picker (preserving return-to-app), rather than jumping to
        // the Home screen.
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: true))
        m.apply(.cancelOnboarding)
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: true))
    }

    func testAuthenticationFailureGoesToFailedPreservingContext() {
        var m = SessionStateMachine(state: .onboarding(.authenticating(server), canReturnToApp: true))
        m.apply(.authenticationFailed(.quickConnectExpired))
        XCTAssertEqual(m.state, .failed(.quickConnectExpired, canReturnToApp: true))
    }

    func testRetryFromFailureWhenAddingReturnsToApp() {
        var m = SessionStateMachine(state: .failed(.serverUnreachable, canReturnToApp: true))
        m.apply(.retry)
        XCTAssertEqual(m.state, .ready)
    }

    func testRetryFromFirstRunFailureReturnsToPicker() {
        var m = SessionStateMachine(state: .failed(.serverUnreachable, canReturnToApp: false))
        m.apply(.retry)
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: false))
    }

    func testRemovingLastAccountReturnsToOnboarding() {
        var m = SessionStateMachine(state: .ready)
        m.apply(.accountsChanged([]))
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: false))
    }

    func testRemovingOneOfSeveralAccountsStaysReady() {
        var m = SessionStateMachine(state: .ready)
        m.apply(.accountsChanged([account()]))
        XCTAssertEqual(m.state, .ready)
    }

    func testIllegalTransitionIsIgnored() {
        var m = SessionStateMachine(state: .onboarding(.selectingServer, canReturnToApp: false))
        m.apply(.accountAuthenticated) // not legal from selectingServer
        XCTAssertEqual(m.state, .onboarding(.selectingServer, canReturnToApp: false))
    }
}

final class AccountStoreTests: XCTestCase {
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []
        var errors: [Error] { lock.withLock { storage } }
        func append(_ error: Error) { lock.withLock { storage.append(error) } }
    }

    private final class ReadFailingSecureStore: SecureStore, @unchecked Sendable {
        enum Failure: Error, Equatable { case unavailable }
        private let base = InMemorySecureStore()
        private let lock = NSLock()
        private var shouldFail = false

        func setReadFailure(_ value: Bool) {
            lock.withLock { shouldFail = value }
        }

        func setString(_ value: String, for key: String) throws {
            try base.setString(value, for: key)
        }

        func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
            try base.insertStringIfAbsent(value, for: key)
        }

        func string(for key: String) -> String? {
            base.string(for: key)
        }

        func readString(for key: String) throws -> String? {
            if lock.withLock({ shouldFail }) { throw Failure.unavailable }
            return try base.readString(for: key)
        }

        func removeValue(for key: String) throws {
            try base.removeValue(for: key)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin)

    private let preEmbyAccountJSON = """
    [
      {
        "id":"jellyfin-account",
        "server":{
          "id":"jf-server",
          "name":"Jellyfin Home",
          "baseURL":"http://jellyfin.local:8096",
          "provider":"jellyfin"
        },
        "userID":"jf-user",
        "userName":"Alice",
        "deviceID":"device",
        "credentialRevision":{"rawValue":"11111111-1111-1111-1111-111111111111"},
        "addedAt":0
      },
      {
        "id":"plex-account",
        "server":{
          "id":"plex-server",
          "name":"Plex Home",
          "baseURL":"https://plex.example.com",
          "provider":"plex"
        },
        "userID":"plex-user",
        "userName":"Bob",
        "deviceID":"device",
        "credentialRevision":{"rawValue":"22222222-2222-2222-2222-222222222222"},
        "addedAt":1
      },
      {
        "id":"share-account",
        "server":{
          "id":"share:server/media",
          "name":"Media Share",
          "baseURL":"smb://server/media",
          "provider":"mediaShare"
        },
        "userID":"guest",
        "userName":"",
        "deviceID":"device",
        "credentialRevision":{"rawValue":"33333333-3333-3333-3333-333333333333"},
        "addedAt":2
      }
    ]
    """

    private func account(_ id: String, user: String = "Alice", added: TimeInterval = 0) -> Account {
        Account(id: id, server: server, userID: "u-\(id)", userName: user, deviceID: "dev", addedAt: Date(timeIntervalSince1970: added))
    }

    func testPreEmbyAccountPayloadStillDecodesEveryExistingProvider() throws {
        let accounts = try JSONDecoder().decode(
            [Account].self,
            from: Data(preEmbyAccountJSON.utf8)
        )

        XCTAssertEqual(accounts.map(\.id), [
            "jellyfin-account",
            "plex-account",
            "share-account"
        ])
        XCTAssertEqual(accounts.map(\.server.provider), [
            .jellyfin,
            .plex,
            .mediaShare
        ])
    }

    func testPreEmbyServerTokensRemainKeyedByStableAccountID() throws {
        let accounts = try JSONDecoder().decode(
            [Account].self,
            from: Data(preEmbyAccountJSON.utf8)
        ).filter { $0.server.provider != .mediaShare }
        let encoded = try JSONEncoder().encode(accounts)
        let secure = InMemorySecureStore()
        try secure.setString(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            for: "com.plozz.accounts.v2"
        )
        try secure.setString(
            "JF_TOKEN",
            for: "com.plozz.account.token.jellyfin-account"
        )
        try secure.setString(
            "PLEX_TOKEN",
            for: "com.plozz.account.token.plex-account"
        )
        let store = AccountStore(secureStore: secure)

        XCTAssertEqual(store.loadAccounts().map(\.id), [
            "jellyfin-account",
            "plex-account"
        ])
        XCTAssertEqual(store.token(for: "jellyfin-account"), "JF_TOKEN")
        XCTAssertEqual(store.token(for: "plex-account"), "PLEX_TOKEN")
    }

    private func shareAccount(
        _ id: String = "share",
        username: String = "alice"
    ) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "share:server/media",
                name: "Media",
                baseURL: URL(string: "smb://server/media")!,
                provider: .mediaShare
            ),
            userID: username.isEmpty ? "guest" : username,
            userName: username,
            deviceID: "dev"
        )
    }

    private func makeShareStore(
        secure: InMemorySecureStore = InMemorySecureStore(),
        stateSecure: InMemorySecureStore = InMemorySecureStore()
    ) throws -> (
        store: AccountStore,
        vault: MediaCredentialVault,
        journal: CredentialMutationJournal,
        secure: InMemorySecureStore,
        stateSecure: InMemorySecureStore
    ) {
        let vault = MediaCredentialVault(secureStore: secure)
        let journal = try CredentialMutationJournal(
            store: DurableLocalStateStore(secureStore: stateSecure)
        )
        return (
            AccountStore(
                secureStore: secure,
                mediaCredentialVault: vault,
                credentialJournal: journal
            ),
            vault,
            journal,
            secure,
            stateSecure
        )
    }

    func testAddLoadRoundTrip() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let acc = account("a1")
        try store.add(acc, token: "TOK1")
        XCTAssertEqual(store.loadAccounts(), [acc])
        XCTAssertEqual(store.token(for: "a1"), "TOK1")
    }

    func testReplacingTokenRotatesCredentialRevision() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let acc = account("a1")
        try store.add(acc, token: "OLD")

        try store.add(acc, token: "NEW")

        let replaced = try XCTUnwrap(store.loadAccounts().first)
        XCTAssertNotEqual(replaced.credentialRevision, acc.credentialRevision)
        XCTAssertEqual(store.token(for: "a1"), "NEW")
    }

    func testMetadataUpdateWithSameTokenPreservesCredentialRevision() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        var acc = account("a1")
        try store.add(acc, token: "TOKEN")
        let originalRevision = acc.credentialRevision
        acc.userName = "Renamed"

        try store.add(acc, token: "TOKEN")

        let updated = try XCTUnwrap(store.loadAccounts().first)
        XCTAssertEqual(updated.credentialRevision, originalRevision)
        XCTAssertEqual(updated.userName, "Renamed")
    }

    func testMultipleAccountsPersistInAddedOrder() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account("a2", added: 200), token: "T2")
        try store.add(account("a1", added: 100), token: "T1")
        XCTAssertEqual(store.loadAccounts().map(\.id), ["a1", "a2"])
        XCTAssertTrue(Set(store.activeAccountIDs()) == ["a1", "a2"])
    }

    func testConcurrentStoreInstancesDoNotDropEachOthersAccounts() throws {
        let secure = InMemorySecureStore()
        let first = AccountStore(secureStore: secure)
        let second = AccountStore(secureStore: secure)
        let queue = DispatchQueue(
            label: "AccountStoreTests.concurrent",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let errorBox = ErrorBox()

        for (store, value) in [(first, account("a1")), (second, account("a2"))] {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try store.add(value, token: "TOKEN")
                } catch {
                    errorBox.append(error)
                }
            }
        }
        group.wait()

        XCTAssertTrue(errorBox.errors.isEmpty)
        XCTAssertEqual(Set(first.loadAccounts().map(\.id)), ["a1", "a2"])
    }

    func testRemoveDeletesAccountAndToken() throws {
        let secure = InMemorySecureStore()
        let store = AccountStore(secureStore: secure)
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        try store.remove(id: "a1")
        XCTAssertEqual(store.loadAccounts().map(\.id), ["a2"])
        XCTAssertNil(store.token(for: "a1"))
        XCTAssertEqual(store.token(for: "a2"), "T2")
        XCTAssertFalse(store.activeAccountIDs().contains("a1"))
    }

    func testActiveSetPersistsAndFiltersStaleIDs() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        store.setActiveAccountIDs(["a2", "ghost"])
        XCTAssertEqual(store.activeAccountIDs(), ["a2"])
    }

    func testClearAllRemovesEverything() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        try store.clearAll()
        XCTAssertTrue(store.loadAccounts().isEmpty)
        XCTAssertNil(store.token(for: "a1"))
        XCTAssertNil(store.token(for: "a2"))
    }

    func testDeviceIDIsStable() {
        let store = AccountStore(secureStore: InMemorySecureStore())
        XCTAssertEqual(store.deviceID(), store.deviceID())
    }

    func testPreviousAccountSchemaIsIgnored() throws {
        let secure = InMemorySecureStore()
        let encoded = try JSONEncoder().encode([account("old")])
        try secure.setString(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            for: "com.plozz.accounts.v1"
        )
        XCTAssertTrue(AccountStore(secureStore: secure).loadAccounts().isEmpty)
    }

    func testSMBCredentialUsesRevisionedVaultInsteadOfLegacyTokenSlot() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "PASSWORD")

        XCTAssertEqual(setup.store.loadAccounts(), [account])
        XCTAssertEqual(setup.store.token(for: account.id), "PASSWORD")
        XCTAssertNil(setup.secure.string(for: "com.plozz.account.token.\(account.id)"))
        XCTAssertEqual(
            try setup.journal.activeRevision(accountID: account.id),
            account.credentialRevision
        )
        XCTAssertEqual(
            try setup.vault.credential(
                accountID: account.id,
                revision: account.credentialRevision,
                expectedTransport: .smb
            ).authentication,
            .password(username: "alice", password: "PASSWORD")
        )
    }

    func testSMBGuestCredentialRoundTripsAsAnonymous() throws {
        let setup = try makeShareStore()
        let account = shareAccount(username: "")
        try setup.store.add(account, token: "")

        XCTAssertEqual(setup.store.token(for: account.id), "")
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: account.id).authentication,
            .anonymous
        )
    }

    func testMediaShareCredentialResolutionRequiresExactActiveRevision() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "PASSWORD")

        XCTAssertEqual(
            try setup.store.mediaShareCredential(
                for: account.id,
                revision: account.credentialRevision
            ).authentication,
            .password(username: "alice", password: "PASSWORD")
        )
        XCTAssertThrowsError(
            try setup.store.mediaShareCredential(
                for: account.id,
                revision: CredentialRevision()
            )
        ) { error in
            XCTAssertEqual(
                error as? AccountStoreError,
                .mediaShareCredentialInvariantViolation
            )
        }
    }

    func testReplacingSMBCredentialCommitsNewRevisionAndRetiresOld() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "OLD")
        try setup.store.add(account, token: "NEW")

        let updated = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertNotEqual(updated.credentialRevision, account.credentialRevision)
        XCTAssertEqual(setup.store.token(for: account.id), "NEW")
        XCTAssertEqual(
            try setup.journal.activeRevision(accountID: account.id),
            updated.credentialRevision
        )
        XCTAssertThrowsError(
            try setup.vault.credential(
                accountID: account.id,
                revision: account.credentialRevision,
                expectedTransport: .smb
            )
        ) {
            XCTAssertEqual($0 as? MediaCredentialError, .credentialNotFound)
        }
    }

    func testSameSMBCredentialPreservesRevision() throws {
        let setup = try makeShareStore()
        var account = shareAccount()
        try setup.store.add(account, token: "SAME")
        account.server.name = "Renamed"
        try setup.store.add(account, token: "SAME")

        let updated = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertEqual(updated.credentialRevision, account.credentialRevision)
        XCTAssertEqual(updated.server.name, "Renamed")
    }

    func testRemovingSMBAccountRetiresCredentialAndPointer() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "PASSWORD")
        try setup.store.remove(id: account.id)

        XCTAssertTrue(setup.store.loadAccounts().isEmpty)
        XCTAssertNil(try setup.journal.activeRevision(accountID: account.id))
        XCTAssertThrowsError(
            try setup.vault.credential(
                accountID: account.id,
                revision: account.credentialRevision,
                expectedTransport: .smb
            )
        )
    }

    func testStagedSMBReplacementRollsBackAfterRelaunch() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "OLD")
        let pendingRevision = CredentialRevision()
        let pendingCredential = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "NEW")
        )
        _ = try setup.journal.begin(
            kind: .credentialReplacement,
            accountID: account.id,
            previousRevision: account.credentialRevision,
            pendingRevision: pendingRevision
        )
        try setup.vault.store(
            pendingCredential,
            accountID: account.id,
            revision: pendingRevision
        )
        var stagedAccount = account
        stagedAccount.credentialRevision = pendingRevision
        try persistAccounts([stagedAccount], secure: setup.secure)

        let relaunched = try makeShareStore(
            secure: setup.secure,
            stateSecure: setup.stateSecure
        )
        try relaunched.store.recoverCredentialMutations()

        XCTAssertEqual(
            try XCTUnwrap(relaunched.store.loadAccounts().first).credentialRevision,
            account.credentialRevision
        )
        XCTAssertEqual(relaunched.store.token(for: account.id), "OLD")
        XCTAssertTrue(try relaunched.journal.mutations().isEmpty)
        XCTAssertThrowsError(
            try relaunched.vault.credential(
                accountID: account.id,
                revision: pendingRevision,
                expectedTransport: .smb
            )
        )
    }

    func testPreparedSMBReplacementCompletesAfterRelaunch() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "OLD")
        let pendingRevision = CredentialRevision()
        let pendingCredential = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "NEW")
        )
        let entry = try setup.journal.begin(
            kind: .credentialReplacement,
            accountID: account.id,
            previousRevision: account.credentialRevision,
            pendingRevision: pendingRevision
        )
        try setup.vault.store(
            pendingCredential,
            accountID: account.id,
            revision: pendingRevision
        )
        var preparedAccount = account
        preparedAccount.credentialRevision = pendingRevision
        try persistAccounts([preparedAccount], secure: setup.secure)
        _ = try setup.journal.markPrepared(entry.id)

        let relaunched = try makeShareStore(
            secure: setup.secure,
            stateSecure: setup.stateSecure
        )
        try relaunched.store.recoverCredentialMutations()

        XCTAssertEqual(
            try XCTUnwrap(relaunched.store.loadAccounts().first).credentialRevision,
            pendingRevision
        )
        XCTAssertEqual(relaunched.store.token(for: account.id), "NEW")
        XCTAssertTrue(try relaunched.journal.mutations().isEmpty)
        XCTAssertThrowsError(
            try relaunched.vault.credential(
                accountID: account.id,
                revision: account.credentialRevision,
                expectedTransport: .smb
            )
        )
    }

    func testPreparedSMBRemovalCompletesAfterRelaunch() throws {
        let setup = try makeShareStore()
        let account = shareAccount()
        try setup.store.add(account, token: "PASSWORD")
        let entry = try setup.journal.begin(
            kind: .accountRemoval,
            accountID: account.id,
            previousRevision: account.credentialRevision,
            pendingRevision: nil
        )
        _ = try setup.journal.markPrepared(entry.id)

        let relaunched = try makeShareStore(
            secure: setup.secure,
            stateSecure: setup.stateSecure
        )
        try relaunched.store.recoverCredentialMutations()

        XCTAssertTrue(relaunched.store.loadAccounts().isEmpty)
        XCTAssertNil(try relaunched.journal.activeRevision(accountID: account.id))
        XCTAssertTrue(try relaunched.journal.mutations().isEmpty)
    }

    func testSMBAccountRequiresCredentialInfrastructure() {
        let store = AccountStore(secureStore: InMemorySecureStore())
        XCTAssertThrowsError(try store.add(shareAccount(), token: "PASSWORD")) {
            XCTAssertEqual(
                $0 as? AccountStoreError,
                .mediaShareCredentialInfrastructureUnavailable
            )
        }
    }

    func testWebDAVRollbackDoesNotRequireAccountMetadataToInferTransport() throws {
        let setup = try makeShareStore()
        let revision = CredentialRevision()
        let accountID = "webdav"
        let credential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "PASSWORD")
        )
        _ = try setup.journal.begin(
            kind: .credentialReplacement,
            accountID: accountID,
            previousRevision: nil,
            pendingRevision: revision
        )
        try setup.vault.store(
            credential,
            accountID: accountID,
            revision: revision
        )

        let relaunched = try makeShareStore(
            secure: setup.secure,
            stateSecure: setup.stateSecure
        )
        try relaunched.store.recoverCredentialMutations()

        XCTAssertTrue(try relaunched.journal.mutations().isEmpty)
        XCTAssertThrowsError(
            try relaunched.vault.credential(
                accountID: accountID,
                revision: revision,
                expectedTransport: .webDAV
            )
        )
    }

    func testHiddenAccountWithIntactCredentialRestoresMissingJournalPointer() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let stale = Account(
            id: "webdav",
            server: MediaServer(
                id: "webdav",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        try persistAccounts([stale], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let oldCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "OLD")
        )
        try setup.vault.store(
            oldCredential,
            accountID: stale.id,
            revision: stale.credentialRevision
        )
        XCTAssertTrue(setup.store.loadAccounts().isEmpty)

        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let newCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: newCredential,
            generatedPrivateKey: nil
        )

        let saved = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertEqual(saved.id, replacement.id)
        XCTAssertNotEqual(saved.credentialRevision, stale.credentialRevision)
        XCTAssertEqual(
            try setup.journal.activeRevision(accountID: stale.id),
            saved.credentialRevision
        )
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: stale.id),
            newCredential
        )
    }

    func testHiddenAccountWithoutCredentialIsReplacedByVerifiedConnection() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let stale = Account(
            id: "webdav",
            server: MediaServer(
                id: "webdav",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        try persistAccounts([stale], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        XCTAssertTrue(setup.store.loadAccounts().isEmpty)

        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let credential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: credential,
            generatedPrivateKey: nil
        )

        XCTAssertEqual(setup.store.loadAccounts(), [replacement])
        XCTAssertEqual(
            try setup.journal.activeRevision(accountID: stale.id),
            replacement.credentialRevision
        )
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: stale.id),
            credential
        )
    }

    func testHiddenMismatchedGeneratedCredentialRetiresItsChildKey() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let stale = Account(
            id: "webdav-mismatch",
            server: MediaServer(
                id: "webdav-mismatch",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        try persistAccounts([stale], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let keyID = try CredentialChildItemID(rawValue: "mismatched-key")
        try setup.vault.storePrivateKey("PRIVATE KEY", id: keyID)
        let mismatched = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(
                sshHostKeySHA256: try SHA256Fingerprint(
                    bytes: Data(repeating: 8, count: 32)
                )
            )
        )
        try setup.vault.store(
            mismatched,
            accountID: stale.id,
            revision: stale.credentialRevision
        )

        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let webDAV = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: webDAV,
            generatedPrivateKey: nil
        )

        XCTAssertThrowsError(try setup.vault.privateKey(id: keyID))
        XCTAssertThrowsError(
            try setup.vault.storePrivateKey("REPLACEMENT", id: keyID)
        ) {
            XCTAssertEqual($0 as? MediaCredentialError, .childItemRetired)
        }
    }

    func testActiveMismatchedGeneratedCredentialRetiresItsChildKey() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let stale = Account(
            id: "active-webdav-mismatch",
            server: MediaServer(
                id: "active-webdav-mismatch",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        try persistAccounts([stale], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let keyID = try CredentialChildItemID(rawValue: "active-mismatched-key")
        try setup.vault.storePrivateKey("PRIVATE KEY", id: keyID)
        let mismatched = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(
                sshHostKeySHA256: try SHA256Fingerprint(
                    bytes: Data(repeating: 9, count: 32)
                )
            )
        )
        try setup.vault.store(
            mismatched,
            accountID: stale.id,
            revision: stale.credentialRevision
        )
        try setup.journal.seedActiveRevision(
            stale.credentialRevision,
            accountID: stale.id
        )

        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let webDAV = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: webDAV,
            generatedPrivateKey: nil
        )

        XCTAssertThrowsError(try setup.vault.privateKey(id: keyID))
        XCTAssertThrowsError(
            try setup.vault.storePrivateKey("REPLACEMENT", id: keyID)
        ) {
            XCTAssertEqual($0 as? MediaCredentialError, .childItemRetired)
        }
    }

    func testActivePointerWithMissingCredentialCanBeReconfigured() throws {
        let setup = try makeShareStore()
        let original = Account(
            id: "webdav",
            server: MediaServer(
                id: "webdav",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let oldCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "OLD")
        )
        try setup.store.addMediaShare(
            original,
            credential: oldCredential,
            generatedPrivateKey: nil
        )
        try setup.vault.remove(
            accountID: original.id,
            revision: original.credentialRevision
        )
        XCTAssertTrue(setup.store.loadAccounts().isEmpty)

        var replacement = original
        replacement.credentialRevision = CredentialRevision()
        let newCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: newCredential,
            generatedPrivateKey: nil
        )

        let saved = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: original.id),
            newCredential
        )
    }

    func testJournalAuthoritativeRevisionRepairsStaleAccountMetadata() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let stale = Account(
            id: "webdav-authoritative",
            server: MediaServer(
                id: "webdav-authoritative",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        try persistAccounts([stale], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let authoritativeRevision = CredentialRevision()
        let authoritativeCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "CURRENT")
        )
        try setup.vault.store(
            authoritativeCredential,
            accountID: stale.id,
            revision: authoritativeRevision
        )
        try setup.journal.seedActiveRevision(
            authoritativeRevision,
            accountID: stale.id
        )
        XCTAssertTrue(setup.store.loadAccounts().isEmpty)

        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let newCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            replacement,
            credential: newCredential,
            generatedPrivateKey: nil
        )

        let saved = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertEqual(saved.id, stale.id)
        XCTAssertNotEqual(saved.credentialRevision, stale.credentialRevision)
        XCTAssertNotEqual(saved.credentialRevision, authoritativeRevision)
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: stale.id),
            newCredential
        )
    }

    func testOrphanJournalPointerReconstructsMissingAccountMetadata() throws {
        let setup = try makeShareStore()
        let account = Account(
            id: "webdav-orphan-pointer",
            server: MediaServer(
                id: "webdav-orphan-pointer",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let authoritativeRevision = CredentialRevision()
        let oldCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "OLD")
        )
        try setup.vault.store(
            oldCredential,
            accountID: account.id,
            revision: authoritativeRevision
        )
        try setup.journal.seedActiveRevision(
            authoritativeRevision,
            accountID: account.id
        )
        XCTAssertTrue(setup.store.loadAccounts().isEmpty)

        let newCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )
        try setup.store.addMediaShare(
            account,
            credential: newCredential,
            generatedPrivateKey: nil
        )

        let saved = try XCTUnwrap(setup.store.loadAccounts().first)
        XCTAssertEqual(saved.id, account.id)
        XCTAssertNotEqual(saved.credentialRevision, authoritativeRevision)
        XCTAssertEqual(
            try setup.store.mediaShareCredential(for: account.id),
            newCredential
        )
    }

    func testRepairNeverDeletesManagedAccountWithCollidingID() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let managed = account("collision")
        try persistAccounts([managed], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let webDAV = Account(
            id: managed.id,
            server: MediaServer(
                id: managed.id,
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let credential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "PASSWORD")
        )

        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                webDAV,
                credential: credential,
                generatedPrivateKey: nil
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .invalidMediaShareAccount)
        }
        XCTAssertEqual(setup.store.loadAccounts(), [managed])
    }

    func testRepairNeverReplacesHiddenShareUsingDifferentTransport() throws {
        let secure = InMemorySecureStore()
        let stateSecure = InMemorySecureStore()
        let staleSMB = shareAccount("collision")
        try persistAccounts([staleSMB], secure: secure)
        let setup = try makeShareStore(secure: secure, stateSecure: stateSecure)
        let webDAV = Account(
            id: staleSMB.id,
            server: MediaServer(
                id: staleSMB.id,
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let credential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "PASSWORD")
        )

        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                webDAV,
                credential: credential,
                generatedPrivateKey: nil
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .invalidMediaShareAccount)
        }
        let persisted = try XCTUnwrap(
            secure.string(for: "com.plozz.accounts.v2")?.data(using: .utf8)
        )
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: persisted), [staleSMB])
    }

    func testTransientCredentialReadFailureDoesNotTriggerRepair() throws {
        let secure = ReadFailingSecureStore()
        let stale = Account(
            id: "webdav",
            server: MediaServer(
                id: "webdav",
                name: "DAV",
                baseURL: URL(string: "https://server.example/dav")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let encodedAccounts = try JSONEncoder().encode([stale])
        try secure.setString(
            try XCTUnwrap(String(data: encodedAccounts, encoding: .utf8)),
            for: "com.plozz.accounts.v2"
        )
        let vault = MediaCredentialVault(secureStore: secure)
        let oldCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "OLD")
        )
        try vault.store(
            oldCredential,
            accountID: stale.id,
            revision: stale.credentialRevision
        )
        let journal = try CredentialMutationJournal(
            store: DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let store = AccountStore(
            secureStore: secure,
            mediaCredentialVault: vault,
            credentialJournal: journal
        )
        var replacement = stale
        replacement.credentialRevision = CredentialRevision()
        let newCredential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .password(username: "alice", password: "NEW")
        )

        secure.setReadFailure(true)
        XCTAssertThrowsError(
            try store.addMediaShare(
                replacement,
                credential: newCredential,
                generatedPrivateKey: nil
            )
        ) {
            XCTAssertEqual($0 as? ReadFailingSecureStore.Failure, .unavailable)
        }
        secure.setReadFailure(false)

        let persisted = try XCTUnwrap(
            secure.string(for: "com.plozz.accounts.v2")?.data(using: .utf8)
        )
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: persisted), [stale])
        XCTAssertEqual(
            try vault.credential(
                accountID: stale.id,
                revision: stale.credentialRevision,
                expectedTransport: .webDAV
            ),
            oldCredential
        )
    }

    func testAccountMetadataReadFailureNeverOverwritesStoredAccounts() throws {
        let secure = ReadFailingSecureStore()
        let existing = account("existing")
        let encoded = try JSONEncoder().encode([existing])
        try secure.setString(
            try XCTUnwrap(String(data: encoded, encoding: .utf8)),
            for: "com.plozz.accounts.v2"
        )
        let store = AccountStore(secureStore: secure)

        secure.setReadFailure(true)
        XCTAssertThrowsError(
            try store.add(account("new"), token: "TOKEN")
        ) {
            XCTAssertEqual($0 as? ReadFailingSecureStore.Failure, .unavailable)
        }
        secure.setReadFailure(false)

        let persisted = try XCTUnwrap(
            secure.string(for: "com.plozz.accounts.v2")?.data(using: .utf8)
        )
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: persisted), [existing])
    }

    func testGeneratedSFTPKeyIsStagedAndRetiredWithCredential() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "key-one")
        let fingerprint = try SHA256Fingerprint(bytes: Data(repeating: 7, count: 32))
        let account = Account(
            id: "sftp",
            server: MediaServer(
                id: "sftp:server/media",
                name: "SFTP",
                baseURL: URL(string: "sftp://server/media")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let credential = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: fingerprint)
        )
        try setup.store.addMediaShare(
            account,
            credential: credential,
            generatedPrivateKey: "PRIVATE KEY"
        )
        XCTAssertEqual(try setup.vault.privateKey(id: keyID), "PRIVATE KEY")

        try setup.store.remove(id: account.id)

        XCTAssertThrowsError(try setup.vault.privateKey(id: keyID))
        XCTAssertThrowsError(
            try setup.vault.storePrivateKey("REPLACEMENT", id: keyID)
        ) {
            XCTAssertEqual($0 as? MediaCredentialError, .childItemRetired)
        }
    }

    func testGeneratedSFTPKeyCannotBeSharedAcrossCredentialRevisions() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "shared-key")
        let firstFingerprint = try SHA256Fingerprint(bytes: Data(repeating: 1, count: 32))
        let secondFingerprint = try SHA256Fingerprint(bytes: Data(repeating: 2, count: 32))
        let account = Account(
            id: "sftp",
            server: MediaServer(
                id: "sftp:server/media",
                name: "SFTP",
                baseURL: URL(string: "sftp://server/media")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let first = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: firstFingerprint)
        )
        try setup.store.addMediaShare(
            account,
            credential: first,
            generatedPrivateKey: "PRIVATE KEY"
        )
        let replacement = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: secondFingerprint)
        )

        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                account,
                credential: replacement,
                generatedPrivateKey: "PRIVATE KEY"
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .generatedKeyReuse)
        }
        XCTAssertEqual(try setup.vault.privateKey(id: keyID), "PRIVATE KEY")
    }

    func testGeneratedSFTPKeyCannotBeSharedAcrossAccounts() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "cross-account-key")
        let fingerprint = try SHA256Fingerprint(bytes: Data(repeating: 5, count: 32))
        func account(_ id: String) -> Account {
            Account(
                id: id,
                server: MediaServer(
                    id: id,
                    name: "SFTP",
                    baseURL: URL(string: "sftp://server/\(id)")!,
                    provider: .mediaShare
                ),
                userID: "alice",
                userName: "alice",
                deviceID: "device"
            )
        }
        let credential = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: fingerprint)
        )
        try setup.store.addMediaShare(
            account("first"),
            credential: credential,
            generatedPrivateKey: "PRIVATE KEY"
        )

        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                account("second"),
                credential: credential,
                generatedPrivateKey: "PRIVATE KEY"
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .generatedKeyReuse)
        }
        XCTAssertEqual(try setup.vault.privateKey(id: keyID), "PRIVATE KEY")
    }

    func testGeneratedSFTPKeyHeldByPreparedRemovalCannotBeReused() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "removing-key")
        let fingerprint = try SHA256Fingerprint(bytes: Data(repeating: 6, count: 32))
        let first = Account(
            id: "removing",
            server: MediaServer(
                id: "removing",
                name: "SFTP",
                baseURL: URL(string: "sftp://server/removing")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let credential = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: fingerprint)
        )
        try setup.store.addMediaShare(
            first,
            credential: credential,
            generatedPrivateKey: "PRIVATE KEY"
        )
        let removal = try setup.journal.begin(
            kind: .accountRemoval,
            accountID: first.id,
            previousRevision: first.credentialRevision,
            pendingRevision: nil
        )
        _ = try setup.journal.markPrepared(removal.id)
        try persistAccounts([], secure: setup.secure)

        let second = Account(
            id: "second",
            server: MediaServer(
                id: "second",
                name: "SFTP",
                baseURL: URL(string: "sftp://server/second")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                second,
                credential: credential,
                generatedPrivateKey: "PRIVATE KEY"
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .generatedKeyReuse)
        }
    }

    func testGeneratedSFTPKeyIDCannotBeReusedAfterChildKeyLoss() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "lost-key")
        let firstFingerprint = try SHA256Fingerprint(
            bytes: Data(repeating: 3, count: 32)
        )
        let secondFingerprint = try SHA256Fingerprint(
            bytes: Data(repeating: 4, count: 32)
        )
        let account = Account(
            id: "sftp-lost",
            server: MediaServer(
                id: "sftp-lost",
                name: "SFTP",
                baseURL: URL(string: "sftp://server/media")!,
                provider: .mediaShare
            ),
            userID: "alice",
            userName: "alice",
            deviceID: "device"
        )
        let original = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(
                sshHostKeySHA256: firstFingerprint
            )
        )
        try setup.store.addMediaShare(
            account,
            credential: original,
            generatedPrivateKey: "PRIVATE KEY"
        )
        try setup.vault.removePrivateKey(id: keyID)

        let replacement = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: keyID),
            trust: MediaShareTrustMaterial(
                sshHostKeySHA256: secondFingerprint
            )
        )
        XCTAssertThrowsError(
            try setup.store.addMediaShare(
                account,
                credential: replacement,
                generatedPrivateKey: "REPLACEMENT KEY"
            )
        ) {
            XCTAssertEqual($0 as? AccountStoreError, .generatedKeyReuse)
        }
    }

    func testStagedGeneratedKeyWithoutEnvelopeIsRetiredDuringRecovery() throws {
        let setup = try makeShareStore()
        let keyID = try CredentialChildItemID(rawValue: "orphan-key")
        let revision = CredentialRevision()
        _ = try setup.journal.begin(
            kind: .generatedKeyPromotion,
            accountID: "sftp",
            previousRevision: nil,
            pendingRevision: revision,
            pendingChildItemIDs: [keyID]
        )
        try setup.vault.storePrivateKey("PRIVATE KEY", id: keyID)

        let relaunched = try makeShareStore(
            secure: setup.secure,
            stateSecure: setup.stateSecure
        )
        try relaunched.store.recoverCredentialMutations()

        XCTAssertThrowsError(try relaunched.vault.privateKey(id: keyID))
        XCTAssertThrowsError(
            try relaunched.vault.storePrivateKey("REPLACEMENT", id: keyID)
        ) {
            XCTAssertEqual($0 as? MediaCredentialError, .childItemRetired)
        }
    }

    private func persistAccounts(
        _ accounts: [Account],
        secure: InMemorySecureStore
    ) throws {
        let data = try JSONEncoder().encode(accounts)
        try secure.setString(
            try XCTUnwrap(String(data: data, encoding: .utf8)),
            for: "com.plozz.accounts.v2"
        )
    }
}

final class SessionStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let session = UserSession(
        server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin),
        userID: "u1", userName: "Alice", deviceID: "dev1", accessToken: "TOPSECRET"
    )

    func testSaveLoadRoundTrip() throws {
        let store = SessionStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        try store.save(session)
        let loaded = store.loadSession()
        XCTAssertEqual(loaded, session)
    }

    func testTokenIsNeverWrittenToUserDefaults() throws {
        let defaults = makeDefaults()
        let store = SessionStore(secureStore: InMemorySecureStore(), defaults: defaults)
        try store.save(session)

        for (_, value) in defaults.dictionaryRepresentation() {
            if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                XCTAssertFalse(text.contains("TOPSECRET"), "Token leaked into UserDefaults")
            }
            if let text = value as? String {
                XCTAssertFalse(text.contains("TOPSECRET"), "Token leaked into UserDefaults")
            }
        }
    }

    func testClearRemovesSession() throws {
        let store = SessionStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        try store.save(session)
        try store.clear()
        XCTAssertNil(store.loadSession())
    }

    func testDeviceIDIsStable() {
        let store = SessionStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        XCTAssertEqual(store.deviceID(), store.deviceID())
    }

    func testLoadReturnsNilWhenTokenMissing() throws {
        let defaults = makeDefaults()
        let secure = InMemorySecureStore()
        let store = SessionStore(secureStore: secure, defaults: defaults)
        try store.save(session)
        try secure.removeValue(for: "com.plozz.session.accessToken")
        XCTAssertNil(store.loadSession())
    }
}
