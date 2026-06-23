import Foundation
#if canImport(Security)
import Security
#endif
import CoreModels

/// Minimal secure key/value store for secrets (access tokens).
///
/// Abstracted behind a protocol so the session layer can be unit-tested with an
/// in-memory double — real Keychain access isn't available in unit tests.
///
/// Refines `CoreModels.SecureStoring` so the same concrete store (e.g.
/// `KeychainStore`) can back both `AccountStore` and `CoreModels.ProfileStore`.
public protocol SecureStore: SecureStoring {
    func setString(_ value: String, for key: String) throws
    func string(for key: String) -> String?
    func removeValue(for key: String) throws
}

#if canImport(Security)
public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

/// `Security.framework`-backed `SecureStore` using a generic-password item.
///
/// Items use `kSecAttrAccessibleAfterFirstThisDeviceOnly` so the token is
/// available after the first unlock following a reboot (tvOS has no passcode
/// prompt) but never leaves the device or syncs to iCloud.
///
/// ## User-independent (household-shared) items
/// When `userIndependent` is `true` (the default on tvOS), queries add
/// `kSecUseUserIndependentKeychain` so the item is reachable by **every** Apple
/// TV system user. This is what lets the household "sign in once": with the
/// `com.apple.developer.user-management` entitlement the default Keychain is
/// partitioned per system user, and this flag is the opt-out that keeps the
/// shared sign-in + profile set visible to all of them.
///
/// If that entitlement isn't present at runtime (e.g. an unprovisioned build),
/// the user-independent query fails with `errSecMissingEntitlement`/
/// `errSecParam`; every operation then transparently **falls back** to a normal
/// (per-user) query so sign-in never hard-breaks — it just isn't shared.
public struct KeychainStore: SecureStore {
    private let service: String
    private let userIndependent: Bool

    public init(service: String = "com.plozz.app.tokens", userIndependent: Bool = true) {
        self.service = service
        self.userIndependent = userIndependent
    }

    private func baseQuery(for key: String, userIndependent: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        #if os(tvOS)
        if userIndependent {
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        }
        #endif
        return query
    }

    /// `true` when a failing status means the user-independent attribute isn't
    /// usable here (entitlement absent) and we should retry per-user.
    private func shouldFallBack(_ status: OSStatus) -> Bool {
        userIndependent && (status == errSecMissingEntitlement || status == errSecParam)
    }

    public func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        func add(useUserIndependent: Bool) -> OSStatus {
            var query = baseQuery(for: key, userIndependent: useUserIndependent)
            // Upsert: delete any existing item first, then add.
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }

        var status = add(useUserIndependent: userIndependent)
        if shouldFallBack(status) { status = add(useUserIndependent: false) }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func string(for key: String) -> String? {
        func copy(useUserIndependent: Bool) -> (OSStatus, AnyObject?) {
            var query = baseQuery(for: key, userIndependent: useUserIndependent)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }

        let (status, result) = copy(useUserIndependent: userIndependent)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }

        // Recovery: an upgrading install's secrets (e.g. access tokens) were
        // written *before* the household/user-independent Keychain was adopted,
        // so they live in the current user's per-user partition and the
        // user-independent read above misses them (errSecItemNotFound), or the
        // entitlement isn't provisioned (errSecMissingEntitlement/errSecParam).
        // Read per-user and, when the shared store is usable, promote the value
        // so every Apple TV system user sees it from then on.
        guard userIndependent else { return nil }
        let (fallbackStatus, fallbackResult) = copy(useUserIndependent: false)
        guard fallbackStatus == errSecSuccess, let data = fallbackResult as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        try? setString(value, for: key) // self-heal into the shared partition
        return value
    }

    public func removeValue(for key: String) throws {
        var status = SecItemDelete(baseQuery(for: key, userIndependent: userIndependent) as CFDictionary)
        if userIndependent {
            // Also clear any legacy per-user copy so a removed secret can't be
            // resurrected by the read-time recovery path in `string(for:)`.
            let perUser = SecItemDelete(baseQuery(for: key, userIndependent: false) as CFDictionary)
            if status == errSecItemNotFound { status = perUser }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
#endif

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
