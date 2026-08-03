import Foundation
import CoreModels
#if canImport(Security)
import Security
#endif

#if canImport(Security)
/// Keychain storage for one tracker's OAuth tokens, shared by every tracker.
///
/// Each tracker used to carry its own byte-identical copy of this — same query
/// shape, same JSON coding, same namespacing — and every copy wrote a
/// `…ThisDeviceOnly` item with no synchronizable attribute. That is the
/// strictest possible setting: it not only skips iCloud Keychain, it forbids it.
/// So signing into a tracker on one device left every other device signed out,
/// while the servers those devices talk to synced fine.
///
/// Items are written synchronizable, which requires dropping `…ThisDeviceOnly`
/// (`KeychainStore` already enforces that pairing). Tokens are still never
/// written anywhere but the Keychain, and never logged.
public final class SyncedTokenBox<Token: Codable & Sendable>: @unchecked Sendable {
    private let service: String
    private let baseAccount: String
    private let lock = NSLock()
    private var namespace: String?
    private let synced: KeychainStore

    public init(
        service: String = "com.plozz.app.tokens",
        account: String,
        namespace: String? = nil
    ) {
        self.service = service
        self.baseAccount = account
        self.namespace = namespace
        // Trackers are account-level, not device-level: the same sign-in is
        // meant to be true everywhere. Not user-independent, because a tracker
        // belongs to a person rather than to the household.
        self.synced = KeychainStore(
            service: service,
            userIndependent: false,
            fallbackToPerUser: false,
            synchronizable: true
        )
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    private func currentAccount() -> String {
        lock.lock(); defer { lock.unlock() }
        if let namespace, !namespace.isEmpty {
            return "\(baseAccount).\(namespace)"
        }
        return baseAccount
    }

    public func load() -> Token? {
        let account = currentAccount()
        if let raw = synced.string(for: account),
           let token = decode(raw) {
            FanoutDiagnostics.emit(
                "keychain.read account=\(account) source=synced "
                + "attrSynchronizable=\(Self.storedSynchronizable(service: service, account: account))"
            )
            return token
        }
        FanoutDiagnostics.emit(
            "keychain.read account=\(account) source=none "
            + "attrSynchronizable=\(Self.storedSynchronizable(service: service, account: account))"
        )
        // Nothing synced yet. A device that signed in before this existed still
        // holds a device-local item; adopt it so switching storage doesn't read
        // as being signed out, and so it reaches this account's other devices.
        guard let legacy = legacyData(account: account),
              let token = try? JSONDecoder().decode(Token.self, from: legacy)
        else { return nil }
        try? save(token)
        removeLegacy(account: account)
        return token
    }

    public func save(_ token: Token) throws {
        let data = try JSONEncoder().encode(token)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SyncedTokenBoxError.encoding
        }
        let account = currentAccount()
        do {
            try synced.setString(raw, for: account)
            // Never the token itself — only whether the synced write landed and
            // whether the item reads back as synchronizable.
            FanoutDiagnostics.emit(
                "keychain.sync account=\(account) write=ok "
                + "readback=\(synced.string(for: account) == nil ? "miss" : "hit") "
                + "attrSynchronizable=\(Self.storedSynchronizable(service: service, account: account))"
            )
        } catch {
            FanoutDiagnostics.emit(
                "keychain.sync account=\(account) write=FAILED error=\(error)"
            )
            throw error
        }
    }

    /// What the Keychain actually recorded for the item, which is the only way to
    /// tell a platform that accepted `kSecAttrSynchronizable` from one that
    /// quietly stored a local item instead.
    static func storedSynchronizable(service: String, account: String) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any] else { return "status:\(status)" }
        let flag = attrs[kSecAttrSynchronizable as String] as? Bool
        return flag.map(String.init) ?? "absent"
    }

    public func clear() throws {
        let account = currentAccount()
        try synced.removeValue(for: account)
        // Signing out must not leave a pre-migration copy behind for `load` to
        // resurrect on the next launch.
        removeLegacy(account: account)
    }

    private func decode(_ raw: String) -> Token? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Token.self, from: data)
    }

    private func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func legacyData(account: String) -> Data? {
        var query = legacyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }
        return result as? Data
    }

    private func removeLegacy(account: String) {
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }
}

public enum SyncedTokenBoxError: Error {
    case encoding
}
#endif
