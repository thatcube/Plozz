#if os(iOS)
import AppRuntime
import CoreModels
import FeatureAuthCore
import Observation

@MainActor
@Observable
final class PlozziOSAppModel {
    let accountsProviders: AccountsProvidersModel

    private let accountStore: AccountPersisting

    var accountError: String?

    init() {
        let accountStore = AccountStore()
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
