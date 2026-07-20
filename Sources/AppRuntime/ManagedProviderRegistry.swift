import CoreModels
import CoreNetworking
import ProviderJellyfin
import ProviderPlex

public enum ManagedProviderRegistry {
    public static func make() -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive)
            )
        }
        registry.register(.emby) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive)
            )
        }
        registry.register(.plex) { context in
            PlexProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                connectionRefresh: PlexProvider.connectionRefresh(for: context.session)
            )
        }
        return registry
    }
}
