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

    func testAddLoadRoundTrip() throws {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        let acc = account("a1")
        try store.add(acc, token: "TOK1")
        XCTAssertEqual(store.loadAccounts(), [acc])
        XCTAssertEqual(store.token(for: "a1"), "TOK1")
    }

    func testMultipleAccountsPersistInAddedOrder() throws {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        try store.add(account("a2", added: 200), token: "T2")
        try store.add(account("a1", added: 100), token: "T1")
        XCTAssertEqual(store.loadAccounts().map(\.id), ["a1", "a2"])
        XCTAssertTrue(Set(store.activeAccountIDs()) == ["a1", "a2"])
    }

    func testTokenIsNeverWrittenToUserDefaults() throws {
        let defaults = makeDefaults()
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: defaults)
        try store.add(account("a1"), token: "TOPSECRET")
        for (_, value) in defaults.dictionaryRepresentation() {
            if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                XCTAssertFalse(text.contains("TOPSECRET"), "Token leaked into UserDefaults")
            }
            if let text = value as? String {
                XCTAssertFalse(text.contains("TOPSECRET"), "Token leaked into UserDefaults")
            }
        }
    }

    func testRemoveDeletesAccountAndToken() throws {
        let secure = InMemorySecureStore()
        let store = AccountStore(secureStore: secure, defaults: makeDefaults())
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        try store.remove(id: "a1")
        XCTAssertEqual(store.loadAccounts().map(\.id), ["a2"])
        XCTAssertNil(store.token(for: "a1"))
        XCTAssertEqual(store.token(for: "a2"), "T2")
        XCTAssertFalse(store.activeAccountIDs().contains("a1"))
    }

    func testActiveSetPersistsAndFiltersStaleIDs() throws {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        store.setActiveAccountIDs(["a2", "ghost"])
        XCTAssertEqual(store.activeAccountIDs(), ["a2"])
    }

    func testClearAllRemovesEverything() throws {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        try store.add(account("a1"), token: "T1")
        try store.add(account("a2", added: 50), token: "T2")
        try store.clearAll()
        XCTAssertTrue(store.loadAccounts().isEmpty)
        XCTAssertNil(store.token(for: "a1"))
        XCTAssertNil(store.token(for: "a2"))
    }

    func testDeviceIDIsStable() {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        XCTAssertEqual(store.deviceID(), store.deviceID())
    }

    // MARK: Migration

    /// Seeds the legacy single-session keys the way `SessionStore` would.
    private func seedLegacySession(defaults: UserDefaults, secure: InMemorySecureStore, token: String) throws {
        let legacy = UserSession(server: server, userID: "u1", userName: "Legacy", deviceID: "dev1", accessToken: token)
        let store = SessionStore(secureStore: secure, defaults: defaults)
        try store.save(legacy)
    }

    func testMigratesLegacySingleSession() throws {
        let defaults = makeDefaults()
        let secure = InMemorySecureStore()
        try seedLegacySession(defaults: defaults, secure: secure, token: "LEGACYTOK")

        let store = AccountStore(secureStore: secure, defaults: defaults)
        XCTAssertTrue(store.migrateLegacySessionIfNeeded())

        let accounts = store.loadAccounts()
        XCTAssertEqual(accounts.count, 1)
        let migrated = try XCTUnwrap(accounts.first)
        XCTAssertEqual(migrated.userName, "Legacy")
        XCTAssertEqual(store.token(for: migrated.id), "LEGACYTOK")
        XCTAssertEqual(store.activeAccountIDs(), [migrated.id])
        // Legacy keys retired.
        XCTAssertNil(secure.string(for: "com.plozz.session.accessToken"))
        XCTAssertNil(defaults.data(forKey: "com.plozz.session.metadata"))
    }

    func testMigrationIsIdempotent() throws {
        let defaults = makeDefaults()
        let secure = InMemorySecureStore()
        try seedLegacySession(defaults: defaults, secure: secure, token: "LEGACYTOK")

        let store = AccountStore(secureStore: secure, defaults: defaults)
        XCTAssertTrue(store.migrateLegacySessionIfNeeded())
        // Second call must be a no-op (accounts schema already present).
        XCTAssertFalse(store.migrateLegacySessionIfNeeded())
        XCTAssertEqual(store.loadAccounts().count, 1)
    }

    func testMigrationNoOpsOnFreshInstall() {
        let store = AccountStore(secureStore: InMemorySecureStore(), defaults: makeDefaults())
        XCTAssertFalse(store.migrateLegacySessionIfNeeded())
        XCTAssertTrue(store.loadAccounts().isEmpty)
    }

    func testMigrationDoesNotClobberExistingAccounts() throws {
        let defaults = makeDefaults()
        let secure = InMemorySecureStore()
        let store = AccountStore(secureStore: secure, defaults: defaults)
        try store.add(account("a1"), token: "T1")
        try seedLegacySession(defaults: defaults, secure: secure, token: "LEGACYTOK")
        // Accounts schema already exists → migration must not run.
        XCTAssertFalse(store.migrateLegacySessionIfNeeded())
        XCTAssertEqual(store.loadAccounts().map(\.id), ["a1"])
    }

    /// Existing installs kept account metadata in `UserDefaults`. Once the
    /// `user-management` entitlement partitions `UserDefaults` per Apple TV user,
    /// that metadata must be lifted into the shared `SecureStore` so the
    /// household stays signed in.
    func testMigratesUserDefaultsMetadataIntoSecureStore() throws {
        let defaults = makeDefaults()
        let acc = account("a1")
        defaults.set(try JSONEncoder().encode([acc]), forKey: "com.plozz.accounts.v1")
        defaults.set(try JSONEncoder().encode(["a1"]), forKey: "com.plozz.accounts.activeIDs")
        defaults.set("device-123", forKey: "com.plozz.session.deviceID")

        let secure = InMemorySecureStore()
        let store = AccountStore(secureStore: secure, defaults: defaults)
        // Reading triggers the one-time UserDefaults → SecureStore lift.
        XCTAssertEqual(store.loadAccounts(), [acc])
        XCTAssertEqual(store.activeAccountIDs(), ["a1"])
        XCTAssertEqual(store.deviceID(), "device-123")
        // Metadata now lives in the shared store and is cleared from per-user defaults.
        XCTAssertNotNil(secure.string(for: "com.plozz.accounts.v1"))
        XCTAssertNil(defaults.data(forKey: "com.plozz.accounts.v1"))
        XCTAssertNil(defaults.string(forKey: "com.plozz.session.deviceID"))
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
