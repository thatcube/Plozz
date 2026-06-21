import Foundation
import Security

/// Minimal secure key/value store for secrets (access tokens).
///
/// Abstracted behind a protocol so the session layer can be unit-tested with an
/// in-memory double — real Keychain access isn't available in unit tests.
public protocol SecureStore: Sendable {
    func setString(_ value: String, for key: String) throws
    func string(for key: String) -> String?
    func removeValue(for key: String) throws
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

/// `Security.framework`-backed `SecureStore` using a generic-password item.
///
/// Items use `kSecAttrAccessibleAfterFirstThisDeviceOnly` so the token is
/// available after the first unlock following a reboot (tvOS has no passcode
/// prompt) but never leaves the device or syncs to iCloud.
public struct KeychainStore: SecureStore {
    private let service: String

    public init(service: String = "com.plizz.app.tokens") {
        self.service = service
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        var query = baseQuery(for: key)
        // Upsert: delete any existing item first, then add.
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory `SecureStore` for tests and previews. **Not** secure.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func removeValue(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
