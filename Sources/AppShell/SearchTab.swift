#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService
import SearchIndexKit

/// Search tab with its own navigation stack: Search → Detail and full-screen
/// player presentation, mirroring `HomeTab`'s wiring. Search is aggregated
/// across every active account; results route to their owning provider.
struct SearchTab: View {
    let accounts: [ResolvedAccount]
    let searchIndexCoordinator: SearchIndexCoordinator
    /// Detail-snapshot cache scoped to the active content identity, threaded from
    /// `MainTabView` so revisit paints never cross a profile/account/credential.
    let detailSnapshotCache: DetailSnapshotCache
    let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    /// Seerr discovery service, backing the "Not in Your Library" search section
    /// and the discovery detail page's one-tap Request.
    let seer: SeerService
    /// The active profile's linked Seerr user (`X-API-User`) for requests, or
    /// `nil` to request as admin.
    let activeSeerrUserID: Int?
    /// Display name of the active profile's linked Seerr user, for "Request as
    /// <name>". `nil` when requesting as admin.
    let activeSeerrUserName: String?
    /// Whether an unmapped (admin) request should confirm first (multi-profile).
    let confirmAdminRequest: Bool
    let homeVisibility: HomeLibraryVisibilityModel
    let behavior: SubtitleBehavior
    let style: SubtitleStyle
    let playbackSettings: PlaybackSettings
    let subtitlePolicy: SubtitlePolicy
    let audioPolicy: AudioPolicy
    let seriesTrackStore: any SeriesTrackPreferenceStoring
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding
    let scrobbler: any TraktScrobbling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Persist an in-player subtitle-appearance edit to the profile store.
    let onSubtitleStyleChanged: (SubtitleStyle) -> Void
    /// Hosted on the root `TabView` (see `MainTabView`) for reliable presentation,
    /// exactly like `HomeTab` — see the note there.
    @Binding var playRequest: PlayRequest?
    @Binding var resumePrompt: MediaItem?

    @State private var path = NavigationPath()

    private func makeHeroTrailerResolver() -> HeroTrailerResolving {
        { item in
            var sources = identitySources(item)
            if let accountID = item.sourceAccountID,
               !sources.contains(where: { $0.accountID == accountID && $0.itemID == item.id }) {
                sources.insert(
                    MediaSourceRef(accountID: accountID, itemID: item.id, kind: item.kind),
                    at: 0
                )
            }
            for source in sources {
                guard let provider = resolveOptionalProvider(source.accountID, in: accounts) else { continue }
                let trailers = (try? await provider.trailers(for: source.itemID)) ?? []
                guard let local = trailers.first(where: { !$0.isYouTubeTrailer }) else { continue }
                guard let request = try? await provider.playbackInfo(for: local.id) else { continue }
                let url: URL?
                if let streamURL = request.streamURL {
                    url = streamURL
                } else if case .some(.authenticatedHTTP(let locator)) = request.playbackSource {
                    url = try? await authenticatedHTTPResolver.resolve(locator)
                } else {
                    url = request.playbackSource?.publicURL
                }
                if let url,
                   let duration = await HeroTrailerController.resolvedDuration(of: url) {
                    return HeroTrailerSource(
                        ownerItemID: item.id,
                        trailerItemID: local.id,
                        url: url,
                        duration: duration
                    )
                }
            }
            return nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(
                viewModel: SearchViewModel(
                    accounts: accounts,
                    identitySources: identitySources,
                    disabledLibraryKeys: { homeVisibility.visibility.disabledKeys },
                    // Fold Seerr discovery hits into a trailing "Not in Your Library"
                    // section. Swallows errors to [] so a Seerr outage never breaks
                    // library search; returns [] when Seerr is unconfigured.
                    seerSearch: { [seer] query in (try? await seer.search(query)) ?? [] },
                    seerRequestAvailability: { [seer] item in
                        await seer.requestAvailability(for: item)
                    },
                    semanticSearch: { [searchIndexCoordinator] query, excluded in
                        await searchIndexCoordinator.semanticSearch(
                            query: query,
                            excludedLibraryKeys: excluded
                        )
                    },
                    semanticIndexBuilding: { [searchIndexCoordinator] in
                        await searchIndexCoordinator.building()
                    }
                ),
                spoilerSettings: spoilerSettings,
                onSelect: { open($0) }
            )
            .navigationDestination(for: MediaItem.self) { item in
                // A discovery (Seerr) result that isn't in the library (id
                // `seer:<tmdbId>`, requestable/in-flight availability) opens the
                // request-focused discovery detail page rather than a library
                // fetch. Search's "Not in Your Library" section only ever surfaces
                // such titles (owned ones are filtered out).
                let isDiscovery = item.isNotInLibraryDiscovery
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(item.sourceAccountID, in: accounts),
                        itemID: item.id,
                        initialItem: item,
                        isDiscoveryItem: isDiscovery,
                        discoveryStatusRefresh: { await seer.availability(for: $0) },
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: item.sourceAccountID,
                        initialSources: item.sources,
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: detailSnapshotCache
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    heroTrailerResolver: makeHeroTrailerResolver(),
                    initialSeasonID: item.seasonID,
                    isDiscoveryItem: isDiscovery,
                    seerConnected: seer.isConfigured,
                    onRequest: { item in
                        let outcome = await seer.request(item, actingUserID: activeSeerrUserID)
                        return seerRequestResult(outcome, actingName: activeSeerrUserName)
                    },
                    requestAvailabilityRefresh: { await seer.requestAvailability(for: $0) },
                    onRequestSeasons: { item, seasons in
                        let outcome = await seer.request(item, seasons: seasons, actingUserID: activeSeerrUserID)
                        return seerRequestResult(outcome, actingName: activeSeerrUserName)
                    },
                    requestActingName: activeSeerrUserName,
                    confirmAdminRequest: confirmAdminRequest
                )
            }
            .navigationDestination(for: EpisodeContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        // Seed the hero from the tapped episode for INSTANT first
                        // paint instead of a centered spinner while the series
                        // resolves (load() swaps in the full series page in place).
                        initialItem: route.episode,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID,
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: detailSnapshotCache
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    heroTrailerResolver: makeHeroTrailerResolver(),
                    initialEpisode: route.episode,
                    seerConnected: seer.isConfigured,
                    requestAvailabilityRefresh: { await seer.requestAvailability(for: $0) },
                    onRequestSeasons: { item, seasons in
                        let outcome = await seer.request(item, seasons: seasons, actingUserID: activeSeerrUserID)
                        return seerRequestResult(outcome, actingName: activeSeerrUserName)
                    },
                    requestActingName: activeSeerrUserName,
                    confirmAdminRequest: confirmAdminRequest
                )
            }
            .navigationDestination(for: SeasonContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        // Seed the hero from the tapped season for INSTANT first
                        // paint instead of a centered spinner while the series
                        // resolves.
                        initialItem: route.season,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID,
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: detailSnapshotCache
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    heroTrailerResolver: makeHeroTrailerResolver(),
                    initialSeasonID: route.season.id,
                    seerConnected: seer.isConfigured,
                    requestAvailabilityRefresh: { await seer.requestAvailability(for: $0) },
                    onRequestSeasons: { item, seasons in
                        let outcome = await seer.request(item, seasons: seasons, actingUserID: activeSeerrUserID)
                        return seerRequestResult(outcome, actingName: activeSeerrUserName)
                    },
                    requestActingName: activeSeerrUserName,
                    confirmAdminRequest: confirmAdminRequest
                )
            }
        }
        .mediaItemNavigator { item in
            if item.kind == .episode, item.seriesID != nil {
                path.append(EpisodeContextRoute(
                    episode: item,
                    originAccountID: nil
                ))
            } else if item.kind == .season, item.seriesID != nil {
                path.append(SeasonContextRoute(
                    season: item,
                    originAccountID: nil
                ))
            } else {
                path.append(item)
            }
        }
    }

    /// Selecting a search result always opens its detail page rather than
    /// playing immediately; episodes/seasons route through their series context
    /// so the detail page has the surrounding show, mirroring `mediaItemNavigator`.
    private func open(_ item: MediaItem) {
        switch item.kind {
        case .episode where item.seriesID != nil:
            path.append(EpisodeContextRoute(
                episode: item,
                originAccountID: nil
            ))
        case .season where item.seriesID != nil:
            path.append(SeasonContextRoute(
                season: item,
                originAccountID: nil
            ))
        default:
            path.append(item)
        }
    }

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        let target = bestSourcePlayItem(item, accounts: accounts, identitySources: identitySources)
        if let resume = target.resumePosition, resume > 1 {
            resumePrompt = target
        } else {
            playRequest = PlayRequest(item: target, startPosition: 0)
        }
    }
}
#endif
