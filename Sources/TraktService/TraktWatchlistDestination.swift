import CoreModels
import CoreNetworking
import Foundation

public actor TraktWatchlistDestination:
    WatchlistDestination, WatchlistReconciliationScopedApplying {
    public nonisolated let id: WatchlistDestinationID
    public nonisolated var reconciliationScope: String {
        id.rawValue + "#" + (
            tokenStore.load()?.stableAccountIdentity ?? "disconnected"
        )
    }
    public nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb, .tmdb, .tvdb, .trakt]
    )

    private let client: TraktClient
    private let auth: TraktAuthService
    private let tokenStore: TraktTokenStoring
    private let profileGeneration: TraktProfileGeneration
    private let operationGate = ConcurrencyLimiter(limit: 1)

    public init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring
    ) {
        id = WatchlistDestinationID(rawValue: "trakt")!
        client = TraktClient(config: config, http: http)
        auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        profileGeneration = TraktProfileGeneration()
    }

    init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring,
        profileGeneration: TraktProfileGeneration
    ) {
        id = WatchlistDestinationID(rawValue: "trakt")!
        client = TraktClient(config: config, http: http)
        auth = TraktAuthService(config: config, http: http)
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
        let result = try await client.watchlist(
            accessToken: validAccessToken()
        )
        return result.movies.compactMap {
            entry(kind: .movie, title: $0)
        } + result.shows.compactMap {
            entry(kind: .series, title: $0)
        }
    }

    public func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
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
        let token = try await validAccessToken()
        guard reconciliationScope == expectedReconciliationScope else {
            throw WatchlistDestinationError.authenticationRequired
        }
        try await client.setWatchlisted(
            desiredState == .present,
            kind: parsed.kind,
            ids: Self.ids(parsed.externalID),
            accessToken: token
        )
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
        kind: MediaItemKind,
        title: TraktWatchlistTitle
    ) -> WatchlistDestinationEntry? {
        let externalIDs = Self.externalIDs(title.ids)
        guard let first = externalIDs.first,
              let binding = WatchlistDestinationBinding(
                destinationID: id,
                opaqueValue: "\(kind.rawValue)|\(first.namespace.rawValue)|\(first.value)"
              ) else { return nil }
        return WatchlistDestinationEntry(
            kind: kind,
            externalIDs: externalIDs,
            binding: binding,
            presentation: title.title.map {
                MediaAliasPresentation(title: $0, year: title.year)
            }
        )
    }

    private static func externalIDs(
        _ ids: TraktWatchlistIDs
    ) -> [WatchlistExternalID] {
        [
            ids.imdb.flatMap {
                WatchlistExternalID(namespace: .imdb, value: $0)
            },
            ids.tmdb.flatMap {
                WatchlistExternalID(namespace: .tmdb, value: String($0))
            },
            ids.tvdb.flatMap {
                WatchlistExternalID(namespace: .tvdb, value: String($0))
            },
            ids.trakt.flatMap {
                WatchlistExternalID(namespace: .trakt, value: String($0))
            }
        ].compactMap { $0 }.sorted()
    }

    private static func ids(
        _ externalID: WatchlistExternalID
    ) -> TraktWatchlistIDs {
        switch externalID.namespace {
        case .imdb:
            guard externalID.value.hasPrefix("tt"),
                  !externalID.value.dropFirst(2).isEmpty,
                  externalID.value.dropFirst(2).allSatisfy(\.isNumber)
            else { return TraktWatchlistIDs() }
            return TraktWatchlistIDs(imdb: externalID.value)
        case .tmdb:
            return TraktWatchlistIDs(tmdb: Int(externalID.value))
        case .tvdb:
            return TraktWatchlistIDs(tvdb: Int(externalID.value))
        case .trakt:
            return TraktWatchlistIDs(trakt: Int(externalID.value))
        case .plex, .aniList, .myAnimeList, .aniDB:
            // Identities Trakt does not index. Never reached in practice, since
            // `capabilities.globalIdentityNamespaces` excludes them.
            return TraktWatchlistIDs()
        }
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
