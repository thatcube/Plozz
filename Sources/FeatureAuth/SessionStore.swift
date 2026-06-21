import Foundation
import CoreModels
import CoreNetworking

/// Persists and restores the authenticated `UserSession`.
///
/// Split storage by sensitivity:
///  * **access token** → Keychain (`SecureStore`);
///  * **non-secret metadata** (server, user id/name, device id) → `UserDefaults`.
///
/// This guarantees the token is never written to a plist and lets relaunch
/// restore a session without re-login (a Phase 1 quality gate).
public protocol SessionPersisting: Sendable {
    /// Stable per-install device id, generated once and reused for all auth.
    func deviceID() -> String
    func save(_ session: UserSession) throws
    func loadSession() -> UserSession?
    func clear() throws
}

public final class SessionStore: SessionPersisting, @unchecked Sendable {
    private struct Metadata: Codable {
        var server: MediaServer
        var userID: String
        var userName: String
        var deviceID: String
    }

    private let secureStore: SecureStore
    private let defaults: UserDefaults
    private let metadataKey = "com.plizz.session.metadata"
    private let deviceIDKey = "com.plizz.session.deviceID"
    private let tokenAccount = "com.plizz.session.accessToken"
    private let lock = NSLock()

    #if canImport(Security)
    public init(secureStore: SecureStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.secureStore = secureStore
        self.defaults = defaults
    }
    #else
    public init(secureStore: SecureStore, defaults: UserDefaults = .standard) {
        self.secureStore = secureStore
        self.defaults = defaults
    }
    #endif

    public func deviceID() -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }

    public func save(_ session: UserSession) throws {
        lock.lock(); defer { lock.unlock() }
        let metadata = Metadata(
            server: session.server,
            userID: session.userID,
            userName: session.userName,
            deviceID: session.deviceID
        )
        let data = try JSONEncoder().encode(metadata)
        defaults.set(data, forKey: metadataKey)
        // Token only ever lives in the Keychain.
        try secureStore.setString(session.accessToken, for: tokenAccount)
        PlizzLog.auth.info("Saved session for user \(session.userName)")
    }

    public func loadSession() -> UserSession? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: metadataKey),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let token = secureStore.string(for: tokenAccount) else {
            return nil
        }
        return UserSession(
            server: metadata.server,
            userID: metadata.userID,
            userName: metadata.userName,
            deviceID: metadata.deviceID,
            accessToken: token
        )
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: metadataKey)
        try secureStore.removeValue(for: tokenAccount)
        PlizzLog.auth.info("Cleared session")
    }
}
