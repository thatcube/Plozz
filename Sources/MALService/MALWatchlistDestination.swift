import CoreModels
import CoreNetworking
import Foundation

/// Syncs the universal watchlist to MyAnimeList's **plan to watch** list.
///
/// Anime-only by construction, the same way ``AniListWatchlistDestination`` is:
/// ``resolve(_:)`` answers `nil` unless the title carries a MAL id, and the
/// reconciler reads that as "this destination has nothing to say about this
/// title". Nothing in the app has to classify what counts as anime.
///
/// Unlike AniList, MAL tokens DO expire and carry a refresh token, so this
/// refreshes on demand — the same shape as Trakt's destination.
public actor MALWatchlistDestination: WatchlistDestination {
    public nonisolated let id: WatchlistDestinationID
    /// MAL indexes only its own ids. An AniList id is deliberately not offered:
    /// translating one would need a third-party mapping service, and inventing an
    /// id is how a viewer ends up with the wrong show on their list.
    public nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.myAnimeList]
    )

    private let client: MALClient
    private let auth: MALAuthService
    private let tokenStore: MALTokenStoring

    public init(
        config: MALConfig,
        http: HTTPClient,
        tokenStore: MALTokenStoring
    ) {
        id = WatchlistDestinationID(rawValue: "myanimelist")!
        client = MALClient(config: config, http: http)
        auth = MALAuthService(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        let response = try await client.planToWatch(
            accessToken: try await validAccessToken()
        )
        return (response.data ?? []).compactMap { entry(from: $0) }
    }

    public func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        // Series only — see AniList's destination for why an anime film in the
        // viewer's library is more likely a mismatch than a genuine match.
        guard target.kind == .series else { return nil }
        guard let external = target.externalIDs.first(where: {
            capabilities.globalIdentityNamespaces.contains($0.namespace)
        }) else { return nil }
        return WatchlistDestinationBinding(
            destinationID: id,
            opaqueValue: "\(target.kind.rawValue)|\(external.namespace.rawValue)|\(external.value)"
        )
    }

    public func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {
        guard binding.destinationID == id,
              let parsed = Self.parse(binding.opaqueValue),
              let animeID = Int(parsed.externalID.value) else {
            throw WatchlistDestinationError.permanent
        }
        let token = try await validAccessToken()
        do {
            if desiredState == .present {
                try await client.updateAnimeListStatus(
                    animeID: animeID,
                    status: .planToWatch,
                    numWatchedEpisodes: nil,
                    accessToken: token
                )
            } else {
                try await client.deleteAnimeListStatus(
                    animeID: animeID,
                    accessToken: token
                )
            }
        } catch AppError.notFound where desiredState == .absent {
            // Nothing to remove: the desired state already holds.
            return
        } catch AppError.unauthorized {
            throw WatchlistDestinationError.authenticationRequired
        } catch {
            throw WatchlistDestinationError.transient
        }
    }

    private func validAccessToken() async throws -> String {
        guard let tokens = tokenStore.load() else {
            throw WatchlistDestinationError.authenticationRequired
        }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            let refreshed = try await auth.refresh(tokens.refreshToken)
            try? tokenStore.save(refreshed)
            return refreshed.accessToken
        } catch AppError.unauthorized {
            throw WatchlistDestinationError.authenticationRequired
        } catch {
            throw WatchlistDestinationError.transient
        }
    }

    private func entry(
        from listEntry: MALAnimeListEntry
    ) -> WatchlistDestinationEntry? {
        guard let node = listEntry.node,
              let animeID = node.id,
              let external = WatchlistExternalID(
                namespace: .myAnimeList,
                value: String(animeID)
              ),
              let binding = WatchlistDestinationBinding(
                destinationID: id,
                opaqueValue: "series|\(external.namespace.rawValue)|\(external.value)"
              ) else { return nil }
        return WatchlistDestinationEntry(
            kind: .series,
            externalIDs: [external],
            binding: binding,
            presentation: node.title.map {
                MediaAliasPresentation(title: $0, year: node.startSeason?.year)
            }
        )
    }

    private static func parse(
        _ value: String
    ) -> (kind: MediaItemKind, externalID: WatchlistExternalID)? {
        let parts = value.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              let kind = MediaItemKind(rawValue: String(parts[0])),
              kind == .movie || kind == .series,
              let namespace = WatchlistExternalID.Namespace(
                rawValue: String(parts[1])
              ),
              let externalID = WatchlistExternalID(
                namespace: namespace,
                value: String(parts[2])
              ) else { return nil }
        return (kind, externalID)
    }
}
