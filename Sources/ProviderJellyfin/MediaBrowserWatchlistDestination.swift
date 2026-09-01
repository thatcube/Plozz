import CoreModels
import Foundation

/// Jellyfin and Emby Favorites adapter. Writes require a locally corroborated
/// provider binding; synced binding hints alone never pass `resolve`.
public struct MediaBrowserWatchlistDestination: WatchlistLibraryResolving {
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

    /// Which item in the viewer's own library this entry is.
    ///
    /// Free here, and exactly answered: a Jellyfin/Emby watchlist IS a set of
    /// library items, so the entry already carries the real item id in its
    /// corroborated binding. No lookup, no network call, and no dependence on a
    /// client-side catalogue scan having finished — which is what left a
    /// watchlisted show reporting "seasons unavailable" until a later refresh
    /// happened to land.
    public func resolveLibraryCopy(
        for entry: WatchlistDestinationEntry
    ) async -> WatchlistLibraryCopy? {
        guard let binding = entry.corroboratedProviderBinding,
              binding.accountDescriptorID == provider.accountID else { return nil }
        return WatchlistLibraryCopy(
            source: MediaSourceRef(
                accountID: provider.accountID,
                itemID: binding.providerItemID,
                kind: entry.kind,
                providerKind: provider.kind
            ),
            // A Jellyfin/Emby favourite IS the library item, so the presentation
            // the destination already read is the owned presentation.
            presentation: entry.presentation
        )
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        let items = try await provider.watchlist()
        var entries: [WatchlistDestinationEntry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            guard item.kind == .movie || item.kind == .series,
                  let key = MediaAliasProviderBindingKey(
                    providerKind: provider.kind,
                    accountDescriptorID: provider.accountID,
                    providerItemID: item.id
                  ),
                  let binding = WatchlistDestinationBinding(
                    destinationID: id,
                    opaqueValue: key.providerItemID
                  ) else {
                // A filtered Favorites response is authoritative. Silently
                // dropping one malformed record would reconcile it as absent.
                throw WatchlistDestinationError.transient
            }
            guard let entry = WatchlistDestinationEntry(
                kind: item.kind,
                externalIDs: Self.externalIDs(item),
                binding: binding,
                corroboratedProviderBinding: key,
                presentation: MediaAliasPresentation(
                    title: item.title,
                    year: item.productionYear,
                    artworkURL: item.posterURL?.absoluteString,
                    backdropURL: item.backdropURL?.absoluteString
                ),
                presentationAccountID: provider.accountID
            ) else {
                throw WatchlistDestinationError.transient
            }
            entries.append(entry)
        }
        return entries
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
