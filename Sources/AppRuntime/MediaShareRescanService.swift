import CoreModels
import CoreNetworking
import ProviderShare

@MainActor
public struct MediaShareRescanService {
    private let accountsProviders: AccountsProvidersModel

    public init(accountsProviders: AccountsProvidersModel) {
        self.accountsProviders = accountsProviders
    }

    public func rescan(accountID: String) {
        guard let account = accountsProviders.accounts.first(where: {
            $0.id == accountID && $0.server.provider == .mediaShare
        }) else {
            return
        }
        let token = accountsProviders.tokenResolver(account.id) ?? ""
        let provider: ShareProvider
        do {
            guard let resolved = try accountsProviders.registry.provider(
                for: accountsProviders.providerResolutionContext(
                    for: account,
                    token: token
                )
            ) as? ShareProvider else {
                PlozzLog.app.error(
                    "Scan now: resolved provider for share \(accountID) is not a ShareProvider"
                )
                return
            }
            provider = resolved
        } catch {
            PlozzLog.app.error(
                "Scan now: provider resolution failed for share \(accountID): \(error)"
            )
            return
        }
        Task { await provider.rescan() }
    }
}
