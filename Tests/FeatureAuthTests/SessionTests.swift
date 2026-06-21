import XCTest
import CoreModels
@testable import FeatureAuth

final class SessionStateMachineTests: XCTestCase {
    private let session = UserSession(
        server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin),
        userID: "u", userName: "A", deviceID: "d", accessToken: "t"
    )
    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://h")!, provider: .jellyfin)

    func testLaunchRestoresExistingSession() {
        var m = SessionStateMachine()
        m.apply(.restored(session))
        XCTAssertEqual(m.state, .authenticated(session))
    }

    func testLaunchWithoutSessionGoesToPicker() {
        var m = SessionStateMachine()
        m.apply(.restored(nil))
        XCTAssertEqual(m.state, .selectingServer)
    }

    func testHappyPath() {
        var m = SessionStateMachine()
        m.apply(.restored(nil))
        m.apply(.serverSelected(server))
        XCTAssertEqual(m.state, .authenticating(server))
        m.apply(.authenticated(session))
        XCTAssertEqual(m.state, .authenticated(session))
    }

    func testAuthenticationFailureGoesToFailed() {
        var m = SessionStateMachine(state: .authenticating(server))
        m.apply(.authenticationFailed(.quickConnectExpired))
        XCTAssertEqual(m.state, .failed(.quickConnectExpired))
    }

    func testSignOutReturnsToPicker() {
        var m = SessionStateMachine(state: .authenticated(session))
        m.apply(.signedOut)
        XCTAssertEqual(m.state, .selectingServer)
    }

    func testCancelFromAuthenticatingReturnsToPicker() {
        // Cancel/Menu on the auth screen must back out to the picker.
        var m = SessionStateMachine(state: .authenticating(server))
        m.apply(.signedOut)
        XCTAssertEqual(m.state, .selectingServer)
    }

    func testIllegalTransitionIsIgnored() {
        var m = SessionStateMachine(state: .selectingServer)
        m.apply(.authenticated(session)) // not legal from selectingServer
        XCTAssertEqual(m.state, .selectingServer)
    }

    func testRetryFromFailure() {
        var m = SessionStateMachine(state: .failed(.serverUnreachable))
        m.apply(.retry)
        XCTAssertEqual(m.state, .selectingServer)
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

        // Scan every persisted UserDefaults value for the secret token.
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
        // Simulate Keychain eviction: token gone but metadata remains.
        try secure.removeValue(for: "com.plozz.session.accessToken")
        XCTAssertNil(store.loadSession())
    }
}
