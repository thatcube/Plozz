#if os(iOS)
import AppRuntime
import CoreModels
import FeatureAuthCore
import Foundation
import MediaTransportCore
import Observation

@MainActor
@Observable
final class PlozziOSAppModel {
    let accountsProviders: AccountsProvidersModel
    let authenticatedHTTPResolver = ManagedAuthenticatedHTTPResolver()
    let settings = PlozziOSSettingsModel()

    private let accountStore: AccountPersisting

    var accountError: String?

    init() {
        let accountStore: AccountStore
        let accountStoreError: String?
        do {
            accountStore = try DefaultAccountStoreFactory.make()
            accountStoreError = nil
        } catch {
            accountStore = DefaultAccountStoreFactory.makeCredentialOnlyFallback()
            accountStoreError = "Network-share credential storage is unavailable: \(error.localizedDescription)"
        }
        let profiles = ProfilesModel(
            defaultActiveAccountIDs: accountStore.activeAccountIDs()
        )
        let accountsProviders = AccountsProvidersModel(
            accountStore: accountStore,
            registry: ManagedProviderRegistry.make(),
            profilesModel: profiles
        )
        accountsProviders.tokenResolver = { accountStore.token(for: $0) }

        self.accountStore = accountStore
        self.accountsProviders = accountsProviders
        accountError = accountStoreError
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
        do {
            try accountStore.remove(id: id)
            accountError = nil
            accountsProviders.reloadAccounts()
        } catch {
            accountError = error.localizedDescription
        }
    }
}
#endif
