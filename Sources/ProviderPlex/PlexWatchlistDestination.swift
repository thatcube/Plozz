import CoreModels
import Foundation

public struct PlexWatchlistDestination: WatchlistLibraryResolving {
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
    /// Resolves the account-level plex.tv token of whoever the profile plays as,
    /// **at the moment of use**.
    ///
    /// A closure, not a captured value: the token is installed asynchronously
    /// (the Home-user switch is a network round trip), so a destination built
    /// during that window captured `nil` and silently fell back to the account
    /// owner's token — reading the owner's watchlist. Reading it per call means
    /// the destination is never stale, whenever it was constructed.
    private let discoverToken: @Sendable () -> String?
    /// Whether this profile plays as a Home user on this account, i.e. whether a
    /// missing token is a real problem rather than "no override needed".
    private let requiresHomeUserToken: Bool

    public init?(
        provider: PlexProvider,
        requiresHomeUserToken: Bool = false,
        discoverToken: @escaping @Sendable () -> String? = { nil }
    ) {
        guard let id = WatchlistDestinationID(
            rawValue: "plex.\(provider.accountID)"
        ) else { return nil }
        self.id = id
        self.provider = provider
        self.requiresHomeUserToken = requiresHomeUserToken
        self.discoverToken = discoverToken
    }

    /// The plex.tv client to use right now, or `nil` when this profile plays as a
    /// Home user whose token hasn't arrived yet.
    ///
    /// Returning `nil` — and doing nothing — is deliberate. The alternative is
    /// the provider's own client, which carries the ACCOUNT OWNER's token, and
    /// using it would read the owner's watchlist into this profile and write this
    /// profile's changes onto the owner's list. Failing closed is the only safe
    /// direction: worst case the watchlist is briefly empty and the next pass
    /// fills it in.
    private var discoverClient: PlexClient? {
        let token = discoverToken()
        if requiresHomeUserToken, token == nil { return nil }
        return provider.client.withDiscoverToken(token)
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        guard let discoverClient else {
            // THROW, don't return []. An empty success means "this list is
            // genuinely empty", and reconciliation would take entries sourced
            // from here as removed and delete them locally. "Couldn't read" is
            // the truth, and the retry policy handles it.
            throw WatchlistDestinationError.transient
        }
        return try await provider.watchlist(using: discoverClient).compactMap { item in
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

    /// Which item in the viewer's own library this watchlist entry is.
    ///
    /// The server that just told us the title is on the watchlist is the same
    /// one that knows whether it holds a copy, so it is asked directly. That
    /// removes the dependency on a client-side catalogue index being complete,
    /// current and published before a watchlisted film can be recognised as one
    /// the viewer already owns.
    ///
    /// Uses the account's own client, not the Discover one: the watchlist is an
    /// account-level list, but the LIBRARY belongs to the server.
    public func resolveLibraryCopy(
        for entry: WatchlistDestinationEntry
    ) async -> MediaSourceRef? {
        // Plex's own id already carries its scheme (`plex://movie/…`), so
        // prefixing it again produced `plex://plex://movie/…` and matched
        // nothing. It is also the id most likely to match, because a library
        // item and a watchlist entry for the same title share it exactly —
        // whereas `/library/all?guid=` matching an EXTERNAL id depends on the
        // server's agent, which is why it is tried after.
        var guids = entry.externalIDs
            .filter { $0.namespace == .plex }
            .map(\.value)
        guids.append(contentsOf: entry.externalIDs
            .filter { $0.namespace != .plex && $0.namespace != .trakt }
            .map { value -> String in
                value.value.contains("://")
                    ? value.value
                    : "\(value.namespace.rawValue)://\(value.value)"
            })
        guard let item = await provider.libraryItem(matchingAnyOf: guids) else {
            return nil
        }
        return MediaSourceRef(
            accountID: provider.accountID,
            itemID: item.id,
            kind: item.kind,
            providerKind: .plex
        )
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
        guard let discoverClient else {
            // Transient by nature: the token is on its way. Retrying is right —
            // writing with the owner's token would put this on the WRONG list.
            throw WatchlistDestinationError.transient
        }
        try await discoverClient.setWatchlisted(
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
