import Foundation
import CoreModels
import CoreSecureStore

/// Mirrors tracker sign-ins between devices through the app's existing
/// end-to-end encrypted CloudKit channel.
///
/// Why this exists at all: tokens belong in the Keychain, and they still live
/// there on every device. But Apple documents that tvOS accepts
/// `kSecAttrSynchronizable` without ever synchronising an app's keychain items
/// through iCloud — measured on device, the Apple TV stored all three connected
/// trackers with `synchronizable=true` while the iPhone's lookup of the very
/// same account returned `errSecItemNotFound`. So iCloud Keychain can carry a
/// sign-in between iPhone and iPad but can neither reach nor leave the Apple TV,
/// which is the device most likely to be signed in first.
///
/// The payload rides in `encryptedValues`, so the field is readable only by this
/// iCloud account — not by Apple, and not by anything inspecting the container.
/// The Keychain remains the store of record on each device; this is transport.
public enum TrackerTokenSyncBridge {
    /// `<service>|<account>`, both of which are already stable, non-secret
    /// identifiers. The record name must not be derived from the token.
    static func recordName(for account: SyncedTokenRegistry.Account) -> SyncRecordID {
        "trackerToken:\(account.service)|\(account.account)"
    }

    static func account(
        fromRecordName name: SyncRecordID
    ) -> SyncedTokenRegistry.Account? {
        let prefix = "trackerToken:"
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let separator = body.firstIndex(of: "|") else { return nil }
        let service = String(body[..<separator])
        let account = String(body[body.index(after: separator)...])
        guard !service.isEmpty, !account.isEmpty else { return nil }
        return SyncedTokenRegistry.Account(service: service, account: account)
    }

    /// Every tracker account this device holds a token for.
    ///
    /// Accounts with no local token are simply absent rather than published as
    /// empty, so a device that has never signed in cannot delete a sign-in that
    /// another device made.
    public static func capture(
        fallback: [SyncRecordID: Data]
    ) -> [SyncRecordID: Data] {
        var records: [SyncRecordID: Data] = [:]
        for account in SyncedTokenRegistry.shared.knownAccounts() {
            let store = SyncedTokenRegistry.store(for: account)
            guard let raw = store.string(for: account.account),
                  let data = raw.data(using: .utf8) else { continue }
            records[recordName(for: account)] = data
        }
        // Anything this device doesn't know about yet stays as it was, rather
        // than being treated as removed.
        for (name, value) in fallback where records[name] == nil {
            guard account(fromRecordName: name) != nil else { continue }
            records[name] = value
        }
        return records
    }

    /// Write incoming sign-ins into the local Keychain.
    ///
    /// A `nil` value is a genuine remote sign-out and clears the local token.
    /// Returns the accounts that actually changed so the caller can refresh the
    /// services holding them.
    @discardableResult
    public static func apply(_ changes: SyncLocalChanges) -> [SyncedTokenRegistry.Account] {
        var touched: [SyncedTokenRegistry.Account] = []
        for (name, value) in changes {
            guard let account = account(fromRecordName: name) else { continue }
            let store = SyncedTokenRegistry.store(for: account)
            guard let value else {
                if store.string(for: account.account) != nil {
                    try? store.removeValue(for: account.account)
                    touched.append(account)
                }
                continue
            }
            guard let raw = String(data: value, encoding: .utf8) else { continue }
            // Don't rewrite an identical token; that would churn the Keychain and
            // re-trigger the change handler on every fetch.
            guard store.string(for: account.account) != raw else { continue }
            try? store.setString(raw, for: account.account)
            SyncedTokenRegistry.shared.register(
                service: account.service,
                account: account.account
            )
            touched.append(account)
        }
        if !touched.isEmpty {
            // The services hold their connection phase in memory, so a token
            // arriving from another device is invisible until they re-read it.
            NotificationCenter.default.post(
                name: .plozzTrackerTokensDidChangeRemotely,
                object: nil
            )
            FanoutDiagnostics.emit(
                "keychain.cloudApply accounts=\(touched.map(\.account).sorted().joined(separator: ","))"
            )
        }
        return touched
    }
}


extension Notification.Name {
    /// A tracker sign-in arrived from another device.
    public static let plozzTrackerTokensDidChangeRemotely = Notification.Name(
        "com.plozz.app.trackerTokensDidChangeRemotely"
    )
}
