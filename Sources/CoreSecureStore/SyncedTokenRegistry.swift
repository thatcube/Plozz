import Foundation

/// The set of tracker keychain accounts this device knows about, so a sync
/// channel can carry them without reaching into each tracker's service module.
///
/// tvOS accepts `kSecAttrSynchronizable` but never uploads an app's keychain
/// items to iCloud (Apple documents this), so the Keychain alone can't carry a
/// tracker sign-in to or from an Apple TV. The Keychain remains where tokens
/// live on each device; this only exposes which accounts exist so they can be
/// mirrored through the app's existing end-to-end encrypted CloudKit channel.
///
/// Registration is by account name rather than by object, so nothing here keeps
/// a token store alive or cares when one is rebuilt for a profile switch.
public final class SyncedTokenRegistry: @unchecked Sendable {
    public static let shared = SyncedTokenRegistry()

    public struct Account: Hashable, Sendable {
        public let service: String
        public let account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    private let lock = NSLock()
    private var accounts: Set<Account> = []
    /// Raised when a token changes locally, so the owner can schedule an upload
    /// instead of the sync layer polling for changes it can't observe.
    private var onChange: (@Sendable () -> Void)?

    private init() {}

    public func register(service: String, account: String) {
        lock.lock()
        accounts.insert(Account(service: service, account: account))
        lock.unlock()
    }

    public func knownAccounts() -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return accounts.sorted {
            $0.service == $1.service ? $0.account < $1.account : $0.service < $1.service
        }
    }

    /// Accounts this device deliberately signed out of.
    ///
    /// Absence of a token is ambiguous — a device that has never signed in looks
    /// identical to one that just signed out — and the two must behave in
    /// opposite ways: the first must leave everyone else alone, the second must
    /// sign every device out. Only a real sign-out records this. Account names
    /// are not secret; no token material is stored here.
    private static let tombstoneDefaultsKey = "com.plozz.app.trackerTokenTombstones"

    private func tombstoneKey(_ account: Account) -> String {
        "\(account.service)|\(account.account)"
    }

    public func markSignedOut(_ account: Account) {
        var stored = Set(
            UserDefaults.standard.stringArray(forKey: Self.tombstoneDefaultsKey) ?? []
        )
        stored.insert(tombstoneKey(account))
        UserDefaults.standard.set(
            Array(stored).sorted(),
            forKey: Self.tombstoneDefaultsKey
        )
    }

    public func clearSignedOut(_ account: Account) {
        var stored = Set(
            UserDefaults.standard.stringArray(forKey: Self.tombstoneDefaultsKey) ?? []
        )
        guard stored.remove(tombstoneKey(account)) != nil else { return }
        UserDefaults.standard.set(
            Array(stored).sorted(),
            forKey: Self.tombstoneDefaultsKey
        )
    }

    public func isSignedOut(_ account: Account) -> Bool {
        let stored = UserDefaults.standard.stringArray(
            forKey: Self.tombstoneDefaultsKey
        ) ?? []
        return stored.contains(tombstoneKey(account))
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); onChange = handler; lock.unlock()
    }

    func noteChanged() {
        lock.lock(); let handler = onChange; lock.unlock()
        handler?()
    }

    /// The store used to read and write a synced account's payload. Kept here so
    /// the sync channel and the token boxes can't drift into different keychain
    /// query shapes for the same item.
    public static func store(for account: Account) -> KeychainStore {
        KeychainStore(
            service: account.service,
            userIndependent: false,
            fallbackToPerUser: false,
            synchronizable: true
        )
    }
}
