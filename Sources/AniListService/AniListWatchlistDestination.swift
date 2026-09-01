import CoreModels
import CoreNetworking
import Foundation

/// Syncs the universal watchlist to AniList's **Planning** list.
///
/// Anime-only by construction rather than by a special case: ``resolve(_:)``
/// answers `nil` unless the title carries an AniList or MyAnimeList id, and the
/// reconciler already treats an unresolvable target as "this destination has
/// nothing to say about this title". So watchlisting Dune never touches AniList,
/// and watchlisting Frieren does — without anywhere in the app having to hold an
/// opinion about what counts as anime.
///
/// That only became possible once ``WatchlistExternalID`` learned the anime
/// namespaces. The identity layer had carried AniList/MAL/AniDB ids all along;
/// the watchlist target was dropping them on the way through, which is why this
/// destination could not previously be written at all.
public actor AniListWatchlistDestination:
    WatchlistDestination, WatchlistReconciliationScopedApplying {
    public nonisolated let id: WatchlistDestinationID
    public nonisolated var reconciliationScope: String {
        let identity = tokenStore.load().map {
            WatchlistReconciliationIdentity.credential($0.accessToken)
        } ?? "disconnected"
        return id.rawValue + "#" + identity
    }
    /// No IMDb/TMDb/TVDb: AniList cannot look a title up by them, and offering an
    /// identity it cannot use would only mint bindings that resolve to nothing.
    ///
    /// AniDB **is** accepted even though AniList's API has no AniDB lookup,
    /// because ``AnimeIDMapper`` translates it — and that matters more than it
    /// sounds. Jellyfin and Plex anime libraries (Shoko especially) usually tag
    /// only AniDB, so without this the destination would decline nearly every
    /// anime the viewer actually owns while appearing to work.
    public nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.aniList, .myAnimeList, .aniDB]
    )

    private let client: AniListClient
    private let tokenStore: AniListTokenStoring
    /// The viewer's AniList user id, needed to read or delete a list entry.
    /// Resolved once and kept: it cannot change without the token changing too.
    private var cachedUserID: Int?
    private var cachedUserCredentialIdentity: String?

    public init(
        config: AniListConfig,
        http: HTTPClient,
        tokenStore: AniListTokenStoring
    ) {
        id = WatchlistDestinationID(rawValue: "anilist")!
        client = AniListClient(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        let token = try accessToken()
        let userID = try await userID(accessToken: token)
        let entries = try await client.planningEntries(
            userID: userID,
            accessToken: token
        )
        return entries.compactMap { entry(from: $0) }
    }

    public func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        // Series only. AniList lists anime films too, but they are catalogued as
        // their own works and a film in the viewer's library rarely carries an
        // AniList id — so a movie reaching here is far more likely to be a
        // mismatch than a genuine anime film.
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
        guard binding.destinationID == id,
              let parsed = Self.parse(binding.opaqueValue) else {
            throw WatchlistDestinationError.permanent
        }
        guard reconciliationScope == expectedReconciliationScope else {
            throw WatchlistDestinationError.authenticationRequired
        }
        let token = try accessToken()
        guard reconciliationScope == expectedReconciliationScope else {
            throw WatchlistDestinationError.authenticationRequired
        }
        do {
            // A MAL id has to be translated into AniList's own media id first;
            // AniList indexes both, so this is a lookup rather than a guess.
            guard let mediaID = try await mediaID(for: parsed.externalID, accessToken: token) else {
                // AniList does not know this title. Permanent: retrying the same
                // lookup will keep returning nothing.
                throw WatchlistDestinationError.permanent
            }
            guard reconciliationScope == expectedReconciliationScope else {
                throw WatchlistDestinationError.authenticationRequired
            }
            if desiredState == .present {
                try await client.saveMediaListEntry(
                    mediaId: mediaID,
                    status: .planning,
                    progress: nil,
                    accessToken: token
                )
            } else {
                let resolvedUserID = try await userID(accessToken: token)
                guard reconciliationScope == expectedReconciliationScope else {
                    throw WatchlistDestinationError.authenticationRequired
                }
                try await client.deleteMediaListEntry(
                    mediaId: mediaID,
                    userID: resolvedUserID,
                    accessToken: token
                )
            }
        } catch let error as WatchlistDestinationError {
            throw error
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

    private func mediaID(
        for externalID: WatchlistExternalID,
        accessToken: String
    ) async throws -> Int? {
        switch externalID.namespace {
        case .aniList:
            return Int(externalID.value)
        case .myAnimeList:
            guard let mal = Int(externalID.value) else { return nil }
            return try await client.findAnime(
                anilistID: nil,
                malID: mal,
                title: nil,
                accessToken: accessToken
            )
        case .aniDB:
            // The same translation both scrobblers already rely on: a keyless,
            // cached AniDB ↔ MAL ↔ AniList lookup. Deliberately NOT a lookup
            // through another tracker — a viewer who connects only AniList must
            // not need a second account for AniList to work.
            guard let anidb = Int(externalID.value) else { return nil }
            let mapped = await AnimeIDMapper.shared.enrich(
                AnimeMappedIDs(anidb: anidb)
            )
            if let anilist = mapped.anilist { return anilist }
            guard let mal = mapped.mal else { return nil }
            return try await client.findAnime(
                anilistID: nil,
                malID: mal,
                title: nil,
                accessToken: accessToken
            )
        default:
            return nil
        }
    }

    private func accessToken() throws -> String {
        guard let tokens = tokenStore.load() else {
            throw WatchlistDestinationError.authenticationRequired
        }
        return tokens.accessToken
    }

    private func userID(accessToken: String) async throws -> Int {
        let credentialIdentity =
            WatchlistReconciliationIdentity.credential(accessToken)
        if let cachedUserID,
           cachedUserCredentialIdentity == credentialIdentity {
            return cachedUserID
        }
        do {
            let viewer = try await client.viewer(accessToken: accessToken)
            cachedUserID = viewer.id
            cachedUserCredentialIdentity = credentialIdentity
            return viewer.id
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
        from planning: AniListPlanningEntry
    ) -> WatchlistDestinationEntry? {
        guard let media = planning.media, let mediaID = media.id else { return nil }
        var externalIDs: [WatchlistExternalID] = []
        if let id = WatchlistExternalID(namespace: .aniList, value: String(mediaID)) {
            externalIDs.append(id)
        }
        if let mal = media.idMal,
           let id = WatchlistExternalID(namespace: .myAnimeList, value: String(mal)) {
            externalIDs.append(id)
        }
        guard let first = externalIDs.sorted().first,
              let binding = WatchlistDestinationBinding(
                destinationID: id,
                opaqueValue: "series|\(first.namespace.rawValue)|\(first.value)"
              ) else { return nil }
        // English where the viewer's catalogue would use it, romaji otherwise —
        // this is only a presentation fallback for a title the library has not
        // matched, so the readable one wins.
        let title = media.title?.english ?? media.title?.romaji
        return WatchlistDestinationEntry(
            kind: .series,
            externalIDs: externalIDs.sorted(),
            binding: binding,
            presentation: title.map {
                MediaAliasPresentation(title: $0, year: media.seasonYear)
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
