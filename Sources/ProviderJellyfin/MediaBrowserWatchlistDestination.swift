import CoreModels
import Foundation

/// Jellyfin and Emby Favorites adapter. Writes require a locally corroborated
/// provider binding; synced binding hints alone never pass `resolve`.
public struct MediaBrowserWatchlistDestination: WatchlistDestination {
    public let id: WatchlistDestinationID
    public let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .validatedLibraryCopy
    )
    public var routing: WatchlistDestinationRouting {
        WatchlistDestinationRouting(
            validatedBindingScopes: [
                WatchlistProviderBindingScope(
                    providerKind: provider.kind,
                    accountDescriptorID: provider.accountID
                )
            ]
        )
    }

    private let provider: JellyfinProvider

    public init?(provider: JellyfinProvider) {
        guard provider.kind.usesMediaBrowserAPI,
              let id = WatchlistDestinationID(
                rawValue: "mediabrowser.\(provider.accountID)"
              ) else { return nil }
        self.id = id
        self.provider = provider
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        try await provider.watchlist().compactMap { item in
            guard item.kind == .movie || item.kind == .series,
                  let key = MediaAliasProviderBindingKey(
                    providerKind: provider.kind,
                    accountDescriptorID: provider.accountID,
                    providerItemID: item.id
                  ),
                  let binding = WatchlistDestinationBinding(
                    destinationID: id,
                    opaqueValue: key.providerItemID
                  ) else { return nil }
            return WatchlistDestinationEntry(
                kind: item.kind,
                externalIDs: Self.externalIDs(item),
                binding: binding,
                corroboratedProviderBinding: key,
                presentation: MediaAliasPresentation(
                    title: item.title,
                    year: item.productionYear,
                    artworkURL: item.posterURL?.absoluteString,
                    backdropURL: item.backdropURL?.absoluteString
                )
            )
        }
    }

    public func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        let validatedItemIDs = target.validatedBindings.filter {
            $0.providerKind == provider.kind
                && $0.accountDescriptorID == provider.accountID
        }.map(\.providerItemID)
        return WatchlistDestinationBinding(
            destinationID: id,
            opaqueValues: validatedItemIDs
        )
    }

    public func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {
        guard binding.destinationID == id else {
            throw WatchlistDestinationError.permanent
        }
        for itemID in binding.opaqueValues {
            try await provider.client.setFavorite(
                desiredState == .present,
                userID: provider.session.userID,
                itemID: itemID
            )
        }
    }

    private static func externalIDs(_ item: MediaItem) -> [WatchlistExternalID] {
        [
            (ProviderIDNamespace.imdb, WatchlistExternalID.Namespace.imdb),
            (.tmdb, .tmdb),
            (.tvdb, .tvdb)
        ].compactMap { namespace, destinationNamespace in
            item.providerID(namespace).flatMap {
                WatchlistExternalID(
                    namespace: destinationNamespace,
                    value: $0
                )
            }
        }
    }
}
