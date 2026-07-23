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
    func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool
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
/// Credential stores default to a per-user fallback when the household
/// entitlement is unavailable so sign-in does not hard-break. Non-recreatable
/// durable local state disables that fallback through
/// `DurableLocalStateStoreFactory` and surfaces the storage failure instead.
public struct KeychainStore: SecureStore {
    private let service: String
    private let userIndependent: Bool
    private let fallbackToPerUser: Bool
    private let synchronizable: Bool

    public init(
        service: String = "com.plozz.app.tokens",
        userIndependent: Bool = true,
        fallbackToPerUser: Bool = true,
        synchronizable: Bool = false
    ) {
        self.service = service
        self.userIndependent = userIndependent
        self.fallbackToPerUser = fallbackToPerUser
        self.synchronizable = synchronizable
    }

    /// Accessibility for written items. Synchronizable items CANNOT be
    /// `…ThisDeviceOnly` (that's what would block iCloud Keychain sync), so a
    /// synchronizable store uses the plain after-first-unlock class.
    private var accessible: CFString {
        synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    private func baseQuery(for key: String, userIndependent: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if synchronizable {
            // Must be present on EVERY query (add/update/copy/delete) or it won't
            // match the synced items. Enables iCloud Keychain propagation.
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
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
        userIndependent
            && fallbackToPerUser
            && (status == errSecMissingEntitlement || status == errSecParam)
    }

    public func setString(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        func upsert(useUserIndependent: Bool) -> OSStatus {
            let query = baseQuery(for: key, userIndependent: useUserIndependent)
            var status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecItemNotFound else { return status }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    query as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            }
            return status
        }

        var status = upsert(useUserIndependent: userIndependent)
        if shouldFallBack(status) { status = upsert(useUserIndependent: false) }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        func add(useUserIndependent: Bool) -> OSStatus {
            var query = baseQuery(for: key, userIndependent: useUserIndependent)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = accessible
            return SecItemAdd(query as CFDictionary, nil)
        }

        var status = add(useUserIndependent: userIndependent)
        if shouldFallBack(status) { status = add(useUserIndependent: false) }
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func readString(for key: String) throws -> String? {
        func copy(useUserIndependent: Bool) -> (OSStatus, AnyObject?) {
            var query = baseQuery(for: key, userIndependent: useUserIndependent)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }

        let (status, result) = copy(useUserIndependent: userIndependent)
        if status == errSecSuccess {
            guard let data = result as? Data else {
                throw KeychainError.encodingFailed
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.encodingFailed
            }
            return value
        }

        // Recovery: an upgrading install's secrets (e.g. access tokens) were
        // written *before* the household/user-independent Keychain was adopted,
        // so they live in the current user's per-user partition and the
        // user-independent read above misses them (errSecItemNotFound), or the
        // entitlement isn't provisioned (errSecMissingEntitlement/errSecParam).
        // Read per-user and, when the shared store is usable, promote the value
        // so every Apple TV system user sees it from then on.
        guard userIndependent, fallbackToPerUser else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError.unexpectedStatus(status)
        }
        guard status == errSecItemNotFound
                || status == errSecMissingEntitlement
                || status == errSecParam else {
            throw KeychainError.unexpectedStatus(status)
        }
        let (fallbackStatus, fallbackResult) = copy(useUserIndependent: false)
        if fallbackStatus == errSecItemNotFound { return nil }
        guard fallbackStatus == errSecSuccess, let data = fallbackResult as? Data else {
            throw KeychainError.unexpectedStatus(fallbackStatus)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try? setString(value, for: key) // best-effort self-heal into the shared partition
        return value
    }

    public func string(for key: String) -> String? {
        try? readString(for: key)
    }

    public func removeValue(for key: String) throws {
        let status = SecItemDelete(
            baseQuery(for: key, userIndependent: userIndependent) as CFDictionary
        )
        if userIndependent, fallbackToPerUser {
            // Also clear any legacy per-user copy so a removed secret can't be
            // resurrected by the read-time recovery path in `string(for:)`.
            let perUser = SecItemDelete(baseQuery(for: key, userIndependent: false) as CFDictionary)
            let sharedSucceeded = status == errSecSuccess
                || status == errSecItemNotFound
                || status == errSecMissingEntitlement
                || status == errSecParam
            guard sharedSucceeded else {
                throw KeychainError.unexpectedStatus(status)
            }
            guard perUser == errSecSuccess || perUser == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(perUser)
            }
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Delete EVERY item stored under this service — not just a single key. Used by
    /// the debug "Erase Everything From iCloud" flow to purge all synced logins
    /// (including credentials synced in from other devices whose keys this device
    /// never knew). For a synchronizable store this also removes the items from
    /// iCloud Keychain, propagating the deletion to the household's other devices.
    public func removeAll() throws {
        func serviceQuery(useUserIndependent: Bool) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            if synchronizable {
                query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            }
            #if os(tvOS)
            if useUserIndependent {
                query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
            }
            #endif
            return query
        }
        let status = SecItemDelete(serviceQuery(useUserIndependent: userIndependent) as CFDictionary)
        let sharedOK = status == errSecSuccess || status == errSecItemNotFound
            || status == errSecMissingEntitlement || status == errSecParam
        guard sharedOK else { throw KeychainError.unexpectedStatus(status) }
        if userIndependent, fallbackToPerUser {
            let perUser = SecItemDelete(serviceQuery(useUserIndependent: false) as CFDictionary)
            guard perUser == errSecSuccess || perUser == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(perUser)
            }
        }
    }
}
#endif

#if canImport(Security)
public enum DurableLocalStateStoreFactory {
    public static func userIndependent(
        maximumPayloadBytes: Int = DurableLocalStateStore.defaultMaximumPayloadBytes
    ) throws -> DurableLocalStateStore {
        try DurableLocalStateStore(
            secureStore: KeychainStore(
                service: DurableLocalStateStore.keychainService,
                userIndependent: true,
                fallbackToPerUser: false
            ),
            maximumPayloadBytes: maximumPayloadBytes
        )
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

    public func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storage[key] == nil else { return false }
        storage[key] = value
        return true
    }

    public func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func readString(for key: String) throws -> String? {
        string(for: key)
    }

    public func removeValue(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
