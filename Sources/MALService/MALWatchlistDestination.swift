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
public actor MALWatchlistDestination:
    WatchlistDestination, WatchlistReconciliationScopedApplying {
    public nonisolated let id: WatchlistDestinationID
    public nonisolated var reconciliationScope: String {
        id.rawValue + "#" + (
            tokenStore.load()?.stableAccountIdentity ?? "disconnected"
        )
    }
    /// MAL's API indexes only its own ids, but ``AnimeIDMapper`` translates the
    /// other anime catalogues into one — the same keyless, cached lookup the
    /// scrobbler already uses. That is what makes this work for real libraries:
    /// Jellyfin and Plex anime (Shoko especially) usually carry only AniDB, so a
    /// MAL-only destination would decline nearly everything the viewer owns.
    public nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.myAnimeList, .aniDB, .aniList]
    )

    private let client: MALClient
    private let auth: MALAuthService
    private let tokenStore: MALTokenStoring
    private let profileGeneration: MALProfileGeneration
    private let operationGate = ConcurrencyLimiter(limit: 1)

    public init(
        config: MALConfig,
        http: HTTPClient,
        tokenStore: MALTokenStoring
    ) {
        self.init(
            config: config,
            http: http,
            tokenStore: tokenStore,
            profileGeneration: MALProfileGeneration()
        )
    }

    init(
        config: MALConfig,
        http: HTTPClient,
        tokenStore: MALTokenStoring,
        profileGeneration: MALProfileGeneration
    ) {
        id = WatchlistDestinationID(rawValue: "myanimelist")!
        client = MALClient(config: config, http: http)
        auth = MALAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        self.profileGeneration = profileGeneration
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        try await operationGate.run { [self] in
            try await fetchEntriesUnserialized()
        }
    }

    private func fetchEntriesUnserialized() async throws
        -> [WatchlistDestinationEntry] {
        let response = try await client.planToWatch(
            accessToken: try await validAccessToken()
        )
        guard let values = response.data else {
            throw WatchlistDestinationError.transient
        }
        var entries: [WatchlistDestinationEntry] = []
        entries.reserveCapacity(values.count)
        for value in values {
            // A malformed record cannot safely become authoritative absence.
            guard let entry = entry(from: value) else {
                throw WatchlistDestinationError.transient
            }
            entries.append(entry)
        }
        return entries
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
        try await apply(
            desiredState,
            to: binding,
            expectedReconciliationScope: reconciliationScope
        )
    }

    public func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding,
        expectedReconciliationScope: String
    ) async throws {
        try await operationGate.run { [self] in
            try await applyUnserialized(
                desiredState,
                to: binding,
                expectedReconciliationScope: expectedReconciliationScope
            )
        }
    }

    private func applyUnserialized(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding,
        expectedReconciliationScope: String
    ) async throws {
        guard binding.destinationID == id,
              let parsed = Self.parse(binding.opaqueValue) else {
            throw WatchlistDestinationError.permanent
        }
        guard reconciliationScope == expectedReconciliationScope else {
            throw WatchlistDestinationError.authenticationRequired
        }
        guard let animeID = await Self.malID(for: parsed.externalID) else {
            // No MAL id exists for this title, or the mapping service has never
            // heard of it. Permanent: the same lookup will keep answering the
            // same way, and retrying forever helps nobody.
            throw WatchlistDestinationError.permanent
        }
        let token = try await validAccessToken()
        guard reconciliationScope == expectedReconciliationScope else {
            throw WatchlistDestinationError.authenticationRequired
        }
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
        } catch AppError.rateLimited(let retryAfter) {
            // Answering a throttle with more requests is the one response
            // guaranteed to make it worse; this parks the whole destination.
            throw WatchlistDestinationError.rateLimited(retryAfter: retryAfter)
        } catch {
            throw WatchlistDestinationError.transient
        }
    }

    /// The MAL id for `externalID`, translating from another anime catalogue when
    /// the library did not record one. Never guesses: an id it cannot translate
    /// yields `nil` rather than something plausible-looking, because a wrong id
    /// puts the wrong show on the viewer's list.
    private static func malID(for externalID: WatchlistExternalID) async -> Int? {
        switch externalID.namespace {
        case .myAnimeList:
            return Int(externalID.value)
        case .aniDB:
            guard let anidb = Int(externalID.value) else { return nil }
            return await AnimeIDMapper.shared.enrich(
                AnimeMappedIDs(anidb: anidb)
            ).mal
        case .aniList:
            guard let anilist = Int(externalID.value) else { return nil }
            return await AnimeIDMapper.shared.enrich(
                AnimeMappedIDs(anilist: anilist)
            ).mal
        default:
            return nil
        }
    }

    private func validAccessToken() async throws -> String {
        let generation = profileGeneration.current
        guard let tokens = tokenStore.load() else {
            throw WatchlistDestinationError.authenticationRequired
        }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            let refreshed = try await auth.refresh(tokens.refreshToken)
                .inheritingAccountIdentity(from: tokens)
            guard profileGeneration.performIfCurrent(
                generation,
                operation: { try? tokenStore.save(refreshed) }
            ) else { throw CancellationError() }
            return refreshed.accessToken
        } catch is CancellationError {
            throw WatchlistDestinationError.transient
        } catch AppError.unauthorized {
            throw WatchlistDestinationError.authenticationRequired
        } catch AppError.rateLimited(let retryAfter) {
            // Answering a throttle with more requests is the one response
            // guaranteed to make it worse; this parks the whole destination.
            throw WatchlistDestinationError.rateLimited(retryAfter: retryAfter)
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
