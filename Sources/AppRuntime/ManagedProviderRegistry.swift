import CoreModels
#if canImport(UIKit)
import UIKit
#endif
import CoreNetworking
import ProviderJellyfin
import ProviderPlex

public enum ManagedProviderRegistry {
    /// Whether this build links the on-device decode engine (Plozzigen).
    ///
    /// This is what a provider tells its server about the client's real
    /// capabilities. Jellyfin and Emby pick direct-play versus transcode from
    /// the device profile we send, so leaving it at the conservative default
    /// tells the server we cannot demux Matroska — and it re-encodes an entire
    /// 4K HEVC remux that the device could have played untouched. Plex is less
    /// visibly affected because its decision leans on its own container rules,
    /// which is exactly why this stayed hidden: the same file direct-played from
    /// Plex and transcoded from Jellyfin on the same device.
    ///
    /// Defined here, next to the registry, so both app shells read one value.
    /// The iOS shell built this registry without the flag while the tvOS shell
    /// passed it, so iPhone and iPad silently advertised a weaker client.
    public static var hybridEngineEnabled: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    public static func make(
        hybridEngineEnabled: Bool = ManagedProviderRegistry.hybridEngineEnabled
    ) -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled
            )
        }
        registry.register(.emby) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled
            )
        }
        registry.register(.plex) { context in
            PlexProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled,
                connectionRefresh: PlexProvider.connectionRefresh(for: context.session)
            )
        }
        return registry
    }
}
