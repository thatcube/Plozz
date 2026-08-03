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
        var signedOut: Set<SyncRecordID> = []
        for account in SyncedTokenRegistry.shared.knownAccounts() {
            let name = recordName(for: account)
            if SyncedTokenRegistry.shared.isSignedOut(account) {
                // Omitted below, which is how the ledger expresses a deletion.
                signedOut.insert(name)
                continue
            }
            let store = SyncedTokenRegistry.store(for: account)
            guard let raw = store.string(for: account.account),
                  let data = raw.data(using: .utf8) else { continue }
            records[name] = data
        }
        for (name, value) in fallback where records[name] == nil {
            guard let account = account(fromRecordName: name) else { continue }
            // A real sign-out must not be resurrected by its own ledger entry.
            guard !signedOut.contains(name) else { continue }
            // Otherwise this device simply doesn't have the token: either it has
            // never signed in, or something local discarded it. Keep publishing
            // what the account already agreed on rather than deleting it, and
            // restore the local copy so the device heals itself instead of
            // waiting for a remote edit it may never get.
            records[name] = value
            let store = SyncedTokenRegistry.store(for: account)
            if store.string(for: account.account) == nil,
               let raw = String(data: value, encoding: .utf8) {
                try? store.setString(raw, for: account.account)
                FanoutDiagnostics.emit(
                    "keychain.cloudHeal account=\(account.account)"
                )
            }
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
                // Another device signed out. Match it, and remember that this is
                // a sign-out rather than a gap, so the next capture doesn't
                // publish the token straight back.
                SyncedTokenRegistry.shared.markSignedOut(account)
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
            SyncedTokenRegistry.shared.clearSignedOut(account)
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
