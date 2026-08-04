import CoreModels
import Foundation

public struct PlexWatchlistDestination: WatchlistDestination {
    public let id: WatchlistDestinationID
    public let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb, .tmdb, .tvdb, .plex]
    )
    public var routing: WatchlistDestinationRouting {
        WatchlistDestinationRouting(
            globalIdentityNamespaces: [.imdb, .tmdb, .tvdb, .plex],
            validatedBindingScopes: [
                WatchlistProviderBindingScope(
                    providerKind: .plex,
                    accountDescriptorID: provider.accountID
                )
            ]
        )
    }

    private let provider: PlexProvider
    /// The plex.tv client for this destination — the provider's, but pointed at
    /// the account-level token of whoever the profile plays as.
    private let client: PlexClient

    public init?(provider: PlexProvider, discoverToken: String? = nil) {
        guard let id = WatchlistDestinationID(
            rawValue: "plex.\(provider.accountID)"
        ) else { return nil }
        self.id = id
        self.provider = provider
        self.client = provider.client.withDiscoverToken(discoverToken)
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        try await provider.watchlist(using: client).compactMap { item in
            guard let guid = item.providerIDs["PlexGuid"],
                  let metadataID = PlexClient.watchlistMetadataID(fromGuid: guid),
                  let binding = WatchlistDestinationBinding(
                    destinationID: id,
                    opaqueValue: metadataID
                  ),
                  let providerBinding = MediaAliasProviderBindingKey(
                    providerKind: .plex,
                    accountDescriptorID: provider.accountID,
                    providerItemID: metadataID
                  ) else { return nil }
            return WatchlistDestinationEntry(
                kind: item.kind,
                externalIDs: Self.externalIDs(item, plexGuid: guid),
                binding: binding,
                corroboratedProviderBinding: providerBinding,
                presentation: MediaAliasPresentation(
                    title: item.title,
                    year: item.productionYear,
                    artworkURL: item.posterURL?.absoluteString,
                    backdropURL: item.backdropURL?.absoluteString
                )
            )
        }
    }

    /// Plex has no exact strong-external-id resolution endpoint in the existing
    /// client. Only a supplied global PlexGuid is safe; title search is forbidden.
    public func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        let externalMetadataID = target.externalIDs.first(where: {
            $0.namespace == .plex
        }).flatMap {
            PlexClient.watchlistMetadataID(fromGuid: $0.value)
                ?? PlexClient.discoverMetadataID(from: $0.value)
        }
        let validatedMetadataID = target.validatedBindings.first(where: {
            $0.providerKind == .plex
                && $0.accountDescriptorID == provider.accountID
        })?.providerItemID
        guard let metadataID = externalMetadataID ?? validatedMetadataID else {
            return nil
        }
        return WatchlistDestinationBinding(
            destinationID: id,
            opaqueValue: metadataID
        )
    }

    public func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {
        guard binding.destinationID == id else {
            throw WatchlistDestinationError.permanent
        }
        try await client.setWatchlisted(
            desiredState == .present,
            metadataID: binding.opaqueValue
        )
    }

    private static func externalIDs(
        _ item: MediaItem,
        plexGuid: String
    ) -> [WatchlistExternalID] {
        var result: [WatchlistExternalID] = [
            WatchlistExternalID(namespace: .plex, value: plexGuid)!
        ]
        for (namespace, watchlistNamespace) in [
            (ProviderIDNamespace.imdb, WatchlistExternalID.Namespace.imdb),
            (.tmdb, .tmdb),
            (.tvdb, .tvdb)
        ] {
            if let value = item.providerID(namespace),
               let id = WatchlistExternalID(
                namespace: watchlistNamespace,
                value: value
               ) {
                result.append(id)
            }
        }
        return result
    }
}
