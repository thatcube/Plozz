#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureAuthCore
import Foundation
import MediaTransportCore
import Observation
import ProviderShare

@MainActor
@Observable
final class PlozziOSAppModel {
    let accountsProviders: AccountsProvidersModel
    let authenticatedHTTPResolver = ManagedAuthenticatedHTTPResolver()
    let mediaShareRuntime: DefaultMediaShareRuntime
    let settings = PlozziOSSettingsModel()

    private let accountStore: AccountPersisting
    private let mediaShareAccountService: MediaShareAccountService
    private let mediaShareConfigurationService: MediaShareAccountConfigurationService

    var accountError: String?

    init() {
        let accountStore: AccountStore
        var launchErrors: [String] = []
        do {
            accountStore = try DefaultAccountStoreFactory.make()
        } catch {
            accountStore = DefaultAccountStoreFactory.makeCredentialOnlyFallback()
            launchErrors.append(
                "Network-share credential storage is unavailable: \(error.localizedDescription)"
            )
        }
        let mediaShareRuntime = DefaultMediaShareRuntime.make(
            accountStore: accountStore,
            artworkCacheLifecycle: PlozziOSMediaShareArtworkCacheLifecycle()
        )
        ArtworkImageCache.shared.configure(
            networkFileService: mediaShareRuntime.artworkNetworkFileService
        )
        let registry = ManagedProviderRegistry.make()
        let durableLocalStateStore: DurableLocalStateStore?
        do {
            durableLocalStateStore = try DurableLocalStateStoreFactory.userIndependent()
        } catch {
            durableLocalStateStore = nil
            launchErrors.append(
                "Local network-share library storage is unavailable: \(error.localizedDescription)"
            )
        }
        mediaShareRuntime.registerProvider(
            into: registry,
            durableLocalStateStore: durableLocalStateStore
        )
        let profiles = ProfilesModel(
            defaultActiveAccountIDs: accountStore.activeAccountIDs()
        )
        let accountsProviders = AccountsProvidersModel(
            accountStore: accountStore,
            registry: registry,
            profilesModel: profiles
        )
        accountsProviders.tokenResolver = { accountStore.token(for: $0) }

        self.accountStore = accountStore
        self.accountsProviders = accountsProviders
        self.mediaShareRuntime = mediaShareRuntime
        self.mediaShareAccountService = MediaShareAccountService(runtime: mediaShareRuntime)
        self.mediaShareConfigurationService = MediaShareAccountConfigurationService(
            accountStore: accountStore
        )
        accountError = launchErrors.isEmpty ? nil : launchErrors.joined(separator: "\n")
        authenticatedHTTPResolver.configure { [weak accountsProviders] locator in
            guard let accountsProviders,
                  let account = accountsProviders.accounts.first(where: {
                      $0.id == locator.accountID
                  }),
                  account.server.provider == locator.provider,
                  account.credentialRevision == locator.credentialRevision,
                  let token = accountStore.token(for: account.id),
                  !token.isEmpty else {
                throw MediaTransportError.authentication(
                    reason: "inactive authenticated HTTP identity"
                )
            }
            let baseURL: URL
            if account.server.provider == .plex {
                let provider = try accountsProviders.registry.provider(
                    for: accountsProviders.providerResolutionContext(
                        for: account,
                        token: token
                    )
                )
                guard let originProvider = provider as? AuthenticatedHTTPOriginProviding else {
                    throw MediaTransportError.unsupportedCapability(
                        "dynamic authenticated HTTP origin"
                    )
                }
                baseURL = originProvider.authenticatedHTTPOrigin
            } else {
                baseURL = account.server.baseURL
            }
            return ManagedAuthenticatedHTTPResolver.Context(
                provider: account.server.provider,
                accountID: account.id,
                credentialRevision: account.credentialRevision,
                baseURL: baseURL,
                token: token
            )
        }
        accountsProviders.reloadAccounts()
    }

    var accounts: [Account] {
        accountsProviders.accounts
    }

    var deviceID: String {
        accountStore.deviceID()
    }

    func persist(_ sessions: [UserSession]) {
        do {
            for session in sessions {
                try accountStore.add(Account(from: session), token: session.accessToken)
            }
            accountError = nil
            accountsProviders.reloadAccounts()
        } catch {
            accountError = error.localizedDescription
        }
    }

    func removeAccount(id: String) {
        let removedAccount = accountsProviders.accounts.first { $0.id == id }
        let shareAccountKey = mediaShareAccountService.mediaShareAccountKey(
            for: removedAccount
        )
        do {
            try accountStore.remove(id: id)
            accountsProviders.reloadAccounts()
            guard !accountsProviders.accounts.contains(where: { $0.id == id }) else {
                return
            }
            if let removedAccount {
                mediaShareAccountService.retireCredential(for: removedAccount)
            }
            if let shareAccountKey {
                mediaShareAccountService.invalidate(shareAccountKey: shareAccountKey)
            }
            accountError = nil
        } catch {
            accountError = error.localizedDescription
        }
    }

    @discardableResult
    func addNFSShare(
        host: String,
        port: Int?,
        exportPath: String,
        displayName: String
    ) -> Bool {
        do {
            _ = try mediaShareConfigurationService.saveNFS(
                host: host,
                port: port,
                exportPath: exportPath,
                displayName: displayName
            )
            accountsProviders.reloadAccounts()
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addSMBShare(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String
    ) -> Bool {
        do {
            _ = try mediaShareConfigurationService.saveSMB(
                host: host,
                port: port,
                share: share,
                username: username,
                password: password,
                displayName: displayName
            )
            accountsProviders.reloadAccounts()
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addWebDAVShare(
        baseURL: URL,
        auth: MediaShareWebDAVAuth,
        trustPin: SHA256Fingerprint?,
        displayName: String
    ) -> Bool {
        do {
            _ = try mediaShareConfigurationService.saveWebDAV(
                baseURL: baseURL,
                auth: auth,
                trustPin: trustPin,
                displayName: displayName
            )
            accountsProviders.reloadAccounts()
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addSFTPShare(
        host: String,
        port: Int?,
        path: String,
        username: String,
        password: String,
        hostKeyPin: SHA256Fingerprint,
        displayName: String
    ) -> Bool {
        do {
            _ = try mediaShareConfigurationService.saveSFTP(
                host: host,
                port: port,
                path: path,
                username: username,
                password: password,
                hostKeyPin: hostKeyPin,
                displayName: displayName
            )
            accountsProviders.reloadAccounts()
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }
}

private struct PlozziOSMediaShareArtworkCacheLifecycle:
    ShareLocalArtworkCacheLifecycle
{
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        await ArtworkImageCache.shared.setPreferredNetworkArtworkAccounts(
            accountKeys,
            revision: revision
        )
    }

    func purge(accountID: String) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(accountID: accountID)
    }

    func purge(accountID: String, credentialRevision: CredentialRevision) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }
}
#endif
