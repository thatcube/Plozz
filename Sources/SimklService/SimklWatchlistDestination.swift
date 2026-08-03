import CoreModels
import CoreNetworking
import Foundation

/// Syncs the universal watchlist to Simkl's "plan to watch" list.
///
/// Simkl already scrobbled what the viewer *watched*; without this it could not
/// carry what they planned to watch, which is most of what a watchlist is for.
/// That mattered more once Trakt's API moved behind a paid tier: Simkl is the
/// free equivalent, and it could only replace Trakt if it did both halves.
///
/// Modelled on ``TraktWatchlistDestination`` and deliberately shaped the same, so
/// the two read as one idea with two backends rather than two integrations that
/// happen to overlap. The differences are Simkl's, not ours:
///
/// - Simkl issues a **non-expiring access token** with no refresh token, so token
///   handling is a load rather than Trakt's refresh dance.
/// - Movies and shows are **separate endpoints**, so a read is two calls.
/// - Removal is `remove-from-list` rather than a list-scoped delete, which takes
///   the title off every list it is on. That is the honest match for "the viewer
///   removed this from their watchlist" — the alternative, leaving it filed under
///   a different list, would silently keep something they took away.
public actor SimklWatchlistDestination: WatchlistDestination {
    public nonisolated let id: WatchlistDestinationID
    /// `trakt` and `plex` are absent on purpose: they identify a title only
    /// within those services. The anime catalogues ARE included — Simkl indexes
    /// AniList/MAL/AniDB ids as well as the film-and-TV ones, which is what makes
    /// it the one destination able to place an anime series by any identity the
    /// viewer's library happens to carry.
    public nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb, .tmdb, .tvdb, .aniList, .myAnimeList, .aniDB]
    )

    private let client: SimklClient
    private let tokenStore: SimklTokenStoring

    public init(
        config: SimklConfig,
        http: HTTPClient,
        tokenStore: SimklTokenStoring
    ) {
        id = WatchlistDestinationID(rawValue: "simkl")!
        client = SimklClient(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        let token = try accessToken()
        // Sequential rather than concurrent: this runs on a reconcile pass, not a
        // render path, and two requests in flight against one small service buys
        // nothing worth the extra pressure.
        let movies = try await client.planToWatch(type: "movies", accessToken: token)
        let shows = try await client.planToWatch(type: "shows", accessToken: token)
        return (movies.movies ?? []).compactMap { entry(kind: .movie, from: $0) }
            + (shows.shows ?? []).compactMap { entry(kind: .series, from: $0) }
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
        guard binding.destinationID == id,
              let parsed = Self.parse(binding.opaqueValue) else {
            throw WatchlistDestinationError.permanent
        }
        let ids = Self.ids(parsed.externalID)
        guard !ids.isEmpty else { throw WatchlistDestinationError.permanent }
        let entry = SimklListMutationEntry(
            ids: ids,
            to: desiredState == .present ? "plantowatch" : nil
        )
        let body = parsed.kind == .movie
            ? SimklListMutationBody(movies: [entry], shows: nil)
            : SimklListMutationBody(movies: nil, shows: [entry])
        let token = try accessToken()
        do {
            if desiredState == .present {
                try await client.addToList(body: body, accessToken: token)
            } else {
                try await client.removeFromList(body: body, accessToken: token)
            }
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

    /// Simkl's token does not expire and has no refresh, so this is a load rather
    /// than Trakt's refresh path. A missing token means the viewer never connected
    /// or has disconnected — `authenticationRequired`, not a failure to retry.
    private func accessToken() throws -> String {
        guard let tokens = tokenStore.load() else {
            throw WatchlistDestinationError.authenticationRequired
        }
        return tokens.accessToken
    }

    private func entry(
        kind: MediaItemKind,
        from listEntry: SimklListEntry
    ) -> WatchlistDestinationEntry? {
        guard let title = listEntry.title else { return nil }
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
        _ ids: SimklResponseIDs?
    ) -> [WatchlistExternalID] {
        guard let ids else { return [] }
        return [
            ids.imdb.flatMap { WatchlistExternalID(namespace: .imdb, value: $0) },
            ids.tmdb.flatMap { WatchlistExternalID(namespace: .tmdb, value: $0.value) },
            ids.tvdb.flatMap { WatchlistExternalID(namespace: .tvdb, value: $0.value) }
        ].compactMap { $0 }.sorted()
    }

    private static func ids(_ externalID: WatchlistExternalID) -> SimklIDs {
        switch externalID.namespace {
        case .imdb:
            // Same shape guard as Trakt's: an id that isn't `tt` + digits is not an
            // IMDb id, and sending it would have the service match nothing at best.
            guard externalID.value.hasPrefix("tt"),
                  !externalID.value.dropFirst(2).isEmpty,
                  externalID.value.dropFirst(2).allSatisfy(\.isNumber)
            else { return SimklIDs() }
            return SimklIDs(imdb: externalID.value)
        case .tmdb:
            return SimklIDs(tmdb: Int(externalID.value))
        case .tvdb:
            return SimklIDs(tvdb: Int(externalID.value))
        case .aniList:
            return SimklIDs(anilist: Int(externalID.value))
        case .myAnimeList:
            return SimklIDs(mal: Int(externalID.value))
        case .aniDB:
            return SimklIDs(anidb: Int(externalID.value))
        case .trakt, .plex:
            // Not identifiers Simkl knows about.
            return SimklIDs()
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
