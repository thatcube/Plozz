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
