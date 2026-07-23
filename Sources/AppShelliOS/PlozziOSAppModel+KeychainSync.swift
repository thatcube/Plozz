#if os(iOS)
import Foundation
import CoreModels
import CoreNetworking
import FeatureAuthCore
import FeatureSyncSetup

// MARK: - PlozziOSAppModel + iCloud Keychain credential auto-connect
//
// The "it just works" credential path for iPhone/iPad. Server descriptors already
// sync (non-secret) over CloudKit; the LOGINS ride iCloud Keychain instead — the
// end-to-end-encrypted store Apple designed for exactly this. Each device publishes
// its account bearer tokens as SYNCHRONIZABLE Keychain items; the user's other
// iOS/iPadOS devices read them and sign in automatically, with NO typing and NO
// pairing. (tvOS can't participate in iCloud Keychain, so it keeps using the LAN
// pairing bridge.)
//
// Only bearer-token accounts (Jellyfin/Plex/Emby) are published here. Media-share
// SSH keys stay device-local (they never leave a device), matching the pairing
// policy.
extension PlozziOSAppModel {

    private static let portableCredService = "com.plozz.portablecred.v1"

    /// A synchronizable (iCloud-Keychain-backed) store for portable credentials.
    private var portableCredStore: KeychainStore {
        KeychainStore(service: Self.portableCredService, userIndependent: false, synchronizable: true)
    }

    /// This device's transferable credentials (bearer tokens + share envelopes). Also
    /// used by the pairing `secretsProvider`, so both paths agree on what's shareable.
    func currentSecretsBundle() -> SyncSecretsBundle {
        Self.buildSecretsBundle(accounts: accountsProviders.accounts, accountStore: accountStore)
    }

    /// Pure builder shared by the instance method above AND the pairing service's
    /// `secretsProvider` (which runs during init, before `self` is usable, so it can
    /// only capture already-initialized properties — not call an instance method).
    static func buildSecretsBundle(accounts: [Account], accountStore: AccountPersisting) -> SyncSecretsBundle {
        var accts: [AccountSecret] = []
        var shares: [ShareSecret] = []
        for account in accounts {
            if account.server.provider == .mediaShare {
                if let envelope = try? accountStore.mediaShareCredential(for: account.id) {
                    if case .generatedKey = envelope.authentication {
                        // The SSH key lives in THIS device's Keychain and never
                        // travels; the paired device re-adds this share (own key).
                        PlozzLog.auth.info("KeychainSync: skipping generated-key share \(account.id)")
                    } else if let encoded = try? MediaShareCredentialCodec.encode(envelope) {
                        shares.append(ShareSecret(accountID: account.id, credentialEnvelope: encoded))
                    }
                }
                continue
            }
            guard let token = accountStore.token(for: account.id) else { continue }
            accts.append(AccountSecret(
                accountID: account.id, provider: account.server.provider, token: token,
                deviceID: account.deviceID,
                trustedOrigin: LocalAuthorization.origin(of: account.server.baseURL)))
        }
        return SyncSecretsBundle(accounts: accts, shares: shares)
    }

    /// WRITE: publish this device's account bearer tokens to the iCloud-Keychain-synced
    /// store so the user's OTHER iPhone/iPad auto-connect with zero taps. Gated on sync
    /// being enabled (the household consent decision).
    func publishPortableCredentials() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        let store = portableCredStore
        var published = 0
        for secret in currentSecretsBundle().accounts {
            guard let data = try? JSONEncoder().encode(secret),
                  let json = String(data: data, encoding: .utf8) else { continue }
            do { try store.setString(json, for: secret.accountID); published += 1 }
            catch { PlozzLog.auth.error("KeychainSync: publish failed for \(secret.accountID): \(error.localizedDescription)") }
        }
        if published > 0 { PlozzLog.auth.info("KeychainSync: published \(published) portable credential(s)") }
    }

    /// Remove a portable credential (an account was signed out on this device), so it
    /// stops auto-connecting the user's other devices.
    func removePortableCredential(_ accountID: String) {
        try? portableCredStore.removeValue(for: accountID)
    }

    /// Debug: purge EVERY synced iCloud-Keychain login for the whole household —
    /// including credentials synced in from other devices whose account IDs this
    /// device never held locally. Because the store is synchronizable, the deletion
    /// propagates through iCloud Keychain to the household's other devices, so no
    /// device silently auto-reconnects afterward. Used by "Erase Everything From
    /// iCloud" to reach a true clean slate for cold-start testing.
    func removeAllPortableCredentials() {
        try? portableCredStore.removeAll()
    }

    /// Whether this device already has a synced iCloud-Keychain login for `accountID`,
    /// i.e. `autoConnectFromSyncedCredentials()` can sign it in with no user action. Used
    /// to suppress the manual "add this server?" prompt when a silent auto-connect will
    /// handle it (e.g. iPhone → iPad, where the login rides iCloud Keychain).
    func hasPortableCredential(_ accountID: String) -> Bool {
        portableCredStore.string(for: accountID) != nil
    }

    /// AUTO-CONNECT (READ): for each server synced from another device but not signed in
    /// here (and not ignored), look for a matching credential in the iCloud-Keychain
    /// synced store and sign in automatically — no typing, no pairing. Safe + idempotent:
    /// only acts on pending (not-yet-local) servers, and `accountStore.add` replaces any
    /// existing entry rather than duplicating.
    func autoConnectFromSyncedCredentials() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        let store = portableCredStore
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        let removedIDs = RemovedAccountsStore().removedIDs
        // Don't auto-resurrect a server the user removed household-wide.
        let pending = PendingSyncedServersStore().pending(excludingLocal: localIDs)
            .filter { !removedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        var connected = 0
        for desc in pending {
            guard let json = store.string(for: desc.id),
                  let data = json.data(using: .utf8),
                  let secret = try? JSONDecoder().decode(AccountSecret.self, from: data) else { continue }
            // Media-share credentials aren't published to the synced store; skip.
            guard desc.provider != .mediaShare else { continue }
            let baseURL = desc.candidateBaseURLs.first
                ?? URL(string: secret.trustedOrigin)
                ?? URL(string: "https://localhost")!
            let server = MediaServer(
                id: desc.serverID, name: desc.serverName, baseURL: baseURL,
                provider: desc.provider,
                connectionURLs: desc.candidateBaseURLs.isEmpty ? nil : desc.candidateBaseURLs)
            let account = Account(
                id: desc.id, server: server, userID: desc.userID, userName: desc.userName,
                avatarURL: desc.avatarURL, deviceID: secret.deviceID)
            do { try accountStore.add(account, token: secret.token); connected += 1 }
            catch { PlozzLog.auth.error("KeychainSync: auto-connect failed for \(desc.id): \(error.localizedDescription)") }
        }
        if connected > 0 {
            PlozzLog.auth.info("KeychainSync: auto-connected \(connected) server(s) from iCloud Keychain")
            accountsProviders.reloadAccounts()
            refreshPendingSyncedServers()
        }
    }
}
#endif
