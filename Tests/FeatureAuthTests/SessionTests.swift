import XCTest
import CoreModels
@testable import FeatureAuth

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
    private func makeDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin)

    private func account(_ id: String, user: String = "Alice", added: TimeInterval = 0) -> Account {
        Account(id: id, server: server, userID: "u-\(id)", userName: user, deviceID: "dev", addedAt: Date(timeIntervalSince1970: added))
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
