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

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
struct HomeTab: View {
    let accounts: [ResolvedAccount]
    /// Detail-snapshot cache scoped to the active content identity, threaded from
    /// `MainTabView` so revisit paints never cross a profile/account/credential.
    let detailSnapshotCache: DetailSnapshotCache
    let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    /// Seerr discovery service backing the hero's featured content seam.
    let seer: SeerService
    /// The active profile's linked Seerr user (`X-API-User`) for requests, or
    /// `nil` to request as admin. Read at request time from the current profile.
    let activeSeerrUserID: Int?
    /// Display name of the active profile's linked Seerr user, for the pre-press
    /// "Request as <name>" label. `nil` when requesting as admin.
    let activeSeerrUserName: String?
    /// Whether an unmapped (admin) request should confirm first — true in a
    /// multi-profile household.
    let confirmAdminRequest: Bool
    let homeVisibility: HomeLibraryVisibilityModel
    let homeLayoutStore: HomeLayoutStoring
    /// Per-profile store for the last successful Home content snapshot (instant
    /// launch paint + silent refresh). Same lifecycle as `homeLayoutStore`.
    let homeContentStore: HomeContentStoring
    /// Per-profile hero carousel settings driving the Home featured section.
    let heroSettings: HeroSettingsModel
    let heroBackground: HeroBackgroundSettingsModel
    let heroTrailerController: HeroTrailerController
    let heroRuntime: HomeHeroRuntimeState
    /// App-wide navigation style, so the carousel's left-edge focus behaviour
    /// (escape to sidebar vs. wrap) matches the surrounding chrome.
    let navigationStyle: NavigationStyle
    let behavior: SubtitleBehavior
    let style: SubtitleStyle
    let playbackSettings: PlaybackSettings
    let subtitlePolicy: SubtitlePolicy
    let audioPolicy: AudioPolicy
    let seriesTrackStore: any SeriesTrackPreferenceStoring
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    /// Whether the on-device Home performance HUD is shown (Settings ▸ Diagnostics).
    let homePerfOverlayEnabled: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding
    let scrobbler: any TraktScrobbling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    @Binding var pendingPlayItemID: String?
    /// Snapshot of the durable outbox's not-yet-confirmed plays, folded into the
    /// Continue Watching row so a reload reflects in-app plays the servers haven't
    /// recorded yet (r8-cw-outbox-patch).
    let pendingWatchMutations: @Sendable () async -> [WatchMutation]
    /// Recently-applied in-progress resume writes, folded into the Continue Watching
    /// row so a server's drain-time timestamp inflation can't re-float a stale play
    /// (h2-cw-clamp).
    let appliedWatchRecency: @Sendable () async -> [String: AppliedResumeRecord]
    /// Persist an in-player subtitle-appearance edit to the profile store.
    let onSubtitleStyleChanged: (SubtitleStyle) -> Void
    /// The video player is hosted on the root `TabView` (see `MainTabView`), not
    /// inside this tab's navigation stack — a `fullScreenCover` attached inside a
    /// stack presents unreliably (it only appears after a stray Back press, which
    /// is why "play from a media-share folder" only fired once you backed out to
    /// Home). These bindings drive that root-level host.
    @Binding var playRequest: PlayRequest?
    @Binding var resumePrompt: MediaItem?

    @State private var path = NavigationPath()

    /// Resolves only a FAST hero trailer: a real local/server extra from any
    /// cross-server copy. Online YouTube ids are deliberately rejected on Home.
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
            HomeView(
                viewModel: HomeViewModel(
                    accounts: accounts,
                    layoutStore: homeLayoutStore,
                    contentStore: homeContentStore,
                    identitySources: identitySources,
                    currentVisibility: { homeVisibility.visibility },
                    pendingWatchMutations: pendingWatchMutations,
                    recentlyAppliedRecency: appliedWatchRecency
                ),
                visibility: homeVisibility,
                activeShareIDs: Set(
                    accounts
                        .filter { $0.account.server.provider == .mediaShare }
                        .map(\.account.id)
                ),
                spoilerSettings: spoilerSettings,
                heroSettings: heroSettings,
                heroBackground: heroBackground,
                heroTrailerController: heroTrailerController,
                heroIsFrontmost: path.isEmpty,
                heroRuntime: heroRuntime,
                heroFeaturedProvider: makeHeroFeaturedProvider(
                    seer: seer,
                    accounts: accounts,
                    hideWatched: heroSettings.settings.hideWatched,
                    identitySources: identitySources
                ),
                heroFeaturedStatusProvider: makeHeroFeaturedStatusProvider(
                    seer: seer,
                    hideWatched: heroSettings.settings.hideWatched
                ),
                heroRandomProvider: makeHeroRandomProvider(
                    accounts: accounts,
                    hideWatched: heroSettings.settings.hideWatched,
                    identitySources: identitySources
                ),
                heroWatchStateRefresher: makeHeroWatchStateRefresher(
                    accounts: accounts,
                    hideWatched: heroSettings.settings.hideWatched,
                    identitySources: identitySources
                ),
                heroMetadataEnricher: makeHeroMetadataEnricher(
                    accounts: accounts,
                    identitySources: identitySources
                ),
                heroTrailerResolver: makeHeroTrailerResolver(),
                homePerfOverlayEnabled: homePerfOverlayEnabled,
                seerConnected: seer.isConfigured,
                onRequestItem: { item in
                    let outcome = await seer.request(item, actingUserID: activeSeerrUserID)
                    if case let .success(status) = outcome { return status }
                    return nil
                },
                navigationStyle: navigationStyle,
                onSelectItem: {
                    // "More Info" opens the detail for the item the user selected —
                    // NOT a play-time best-source retarget. Retargeting here can hop
                    // to a bad cross-server twin (a mis-indexed same-kind source that
                    // survives the kind filter because the episode split-guard is
                    // inactive), opening an unrelated title. The detail page owns its
                    // own multi-server source resolution (crossServerSourceResolver +
                    // server picker), so best-source selection still happens there and
                    // at play time (requestPlay).
                    heroTrailerController.captureHandoffFrame()
                    navigate($0)
                },
                onPlayItem: { requestPlay($0) },
                onSelectLibrary: { library in
                    path.append(library)
                }
            )
            .navigationDestination(for: MediaLibrary.self) { library in
                let browse = resolveLibraryBrowse(for: library, in: accounts, identitySources: identitySources)
                LibraryBrowseView(
                    viewModel: LibraryBrowseViewModel(
                        provider: browse.provider,
                        containerID: library.id,
                        containerKind: library.kind,
                        sourceAccountID: browse.sourceAccountID
                    ),
                    title: library.title,
                    spoilerSettings: spoilerSettings,
                    onSelect: {
                        navigate(
                            $0,
                            libraryOrigin: browse.sourceAccountID ?? library.sourceAccountID
                        )
                    }
                )
            }
            .navigationDestination(for: MediaItem.self) { item in
                // Home/Search rows: cross-server-merged, so the detail picker
                // defaults to the smart best version (no library origin).
                itemDetail(for: item, libraryOrigin: nil)
            }
            .navigationDestination(for: LibraryDetailRoute.self) { route in
                // Opened from a library tile: default detail + playback to THAT
                // library's server (the picker still lets the user switch).
                itemDetail(for: route.item, libraryOrigin: route.originAccountID)
            }
            .navigationDestination(for: EpisodeContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        // Seed the hero from the tapped episode so first paint is
                        // INSTANT (its thumbnail + title) instead of a centered
                        // spinner on blank gray while `item(id:)` resolves the
                        // series. load() swaps in the full series page in place.
                        initialItem: route.episode,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID,
                        originSourceAccountID: route.originAccountID,
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does —
                        // discovery matches the series by provider IDs and fills
                        // the server list once the page settles.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: detailSnapshotCache
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    heroTrailerResolver: makeHeroTrailerResolver(),
                    preservesHeroTrailerOnDisappear: true,
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
                        // Seed the hero from the tapped season so first paint is
                        // INSTANT (its poster + title) instead of a centered spinner
                        // on blank gray while `item(id:)` resolves the series.
                        initialItem: route.season,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID,
                        originSourceAccountID: route.originAccountID,
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: detailSnapshotCache
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    heroTrailerResolver: makeHeroTrailerResolver(),
                    preservesHeroTrailerOnDisappear: true,
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
        .task(id: pendingPlayItemID) { await handleDeepLink() }
        .mediaItemNavigator { navigate($0) }
    }

    /// Resolves a deep-linked item id (from a Top Shelf card) and routes to it,
    /// then clears the request so it fires exactly once. Because the id alone is
    /// provider-ambiguous once content is merged, each active provider is tried
    /// until one resolves the item; the resolved item is tagged with its source.
    private func handleDeepLink() async {
        guard let id = pendingPlayItemID else { return }
        pendingPlayItemID = nil
        for resolved in accounts {
            if let item = try? await resolved.provider.item(id: id) {
                requestPlay(item.taggingSource(resolved.account.id))
                return
            }
        }
    }

    /// Pushes a detail page for any item — movies get a Movie Details page (with a
    /// Play button); series/seasons get their children list. A tapped episode is
    /// redirected to its *series* page (fronting that episode) so the user never
    /// lands on a dead-end single-episode page. Immediate playback is reserved for
    /// Continue Watching and the detail page's own Play action.
    ///
    /// `libraryOrigin` carries the owning `Account.id` when the navigation springs
    /// from a single-server library tile, so the pushed detail (and any movie/
    /// collection children it spawns) defaults its cross-server picker to that
    /// server. `nil` for Home/Search rows, which keep the smart best-version
    /// default. Episode/season routes carry the same origin because their series
    /// page can discover alternate servers after opening.
    private func navigate(_ item: MediaItem, libraryOrigin: String? = nil) {
        if item.kind == .episode, item.seriesID != nil {
            path.append(EpisodeContextRoute(
                episode: item,
                originAccountID: libraryOrigin
            ))
        } else if item.kind == .season, item.seriesID != nil {
            path.append(SeasonContextRoute(
                season: item,
                originAccountID: libraryOrigin
            ))
        } else if let libraryOrigin {
            path.append(LibraryDetailRoute(item: item, originAccountID: libraryOrigin))
        } else {
            path.append(item)
        }
    }

    /// Builds the item-detail page, threading the optional `libraryOrigin` into the
    /// view model (so the picker defaults origin-aware) and forwarding it to child
    /// navigation so a movie/collection opened deeper inside a library stays
    /// pinned to its library's server.
    @ViewBuilder
    private func itemDetail(for item: MediaItem, libraryOrigin: String?) -> some View {
        // A discovery (Seerr) title that isn't in the library — e.g. a "More Info"
        // tap on a *not-owned* featured hero slide — routes to the request-focused
        // discovery detail page instead of a doomed library fetch. Owned featured
        // titles (available/partiallyAvailable) are NOT discovery: they resolve to
        // a real library copy via the identity index, so they keep the normal
        // playable detail page.
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
                originSourceAccountID: libraryOrigin,
                initialSources: item.sources,
                alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                snapshotCache: detailSnapshotCache
            ),
            spoilerSettings: spoilerSettings,
            onPlay: { requestPlay($0) },
            onSelectChild: { navigate($0, libraryOrigin: libraryOrigin) },
            heroTrailerResolver: makeHeroTrailerResolver(),
            preservesHeroTrailerOnDisappear: true,
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

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        let target = bestSourcePlayItem(item, accounts: accounts, identitySources: identitySources)
        // A whole series can't be direct-played (its container has no media, so
        // `playbackInfo` for a series ratingKey returns notFound). Resolve its
        // next-up / resume EPISODE and play that — matching Apple TV's hero Play.
        // If we can't resolve an episode (e.g. the show isn't really in the library
        // or the fetch fails), fall back to opening the show's detail page.
        if target.kind == .series {
            Task { @MainActor in
                if let episode = await resolveSeriesNextUpEpisode(target) {
                    presentPlay(bestSourcePlayItem(episode, accounts: accounts, identitySources: identitySources))
                } else {
                    navigate(target)
                }
            }
            return
        }
        presentPlay(target)
    }

    /// Presents the player for an already-resolved, directly-playable `target`
    /// (movie or episode), prompting Resume vs Start Over when it has progress.
    private func presentPlay(_ target: MediaItem) {
        if let resume = target.resumePosition, resume > 1 {
            HandoffDiagnostics.emit(
                "tap RESUME_PROMPT item=\(target.id) provider=\(target.sourceAccountID ?? "nil")"
            )
            resumePrompt = target
        } else {
            let request = PlayRequest(item: target, startPosition: 0)
            HandoffDiagnostics.emit(
                "tap PLAY trace=\(request.traceID.uuidString.prefix(8)) item=\(target.id) "
                    + "provider=\(target.sourceAccountID ?? "nil")"
            )
            playRequest = request
        }
    }

    /// Resolves a series to the episode Play should start: the next-up / resume
    /// episode of its next-up season. Mirrors the detail page's selection
    /// (``SeriesResume/nextUp(in:)``) so the hero's Play matches what the show page
    /// would front. Returns `nil` when no episode can be resolved (the caller then
    /// opens the show detail instead). The episode is stamped with the series'
    /// account so best-source routing and playback address the right server.
    private func resolveSeriesNextUpEpisode(_ series: MediaItem) async -> MediaItem? {
        let provider = resolveProvider(series.sourceAccountID, in: accounts)
        let topChildren = (try? await provider.children(of: series.id)) ?? []
        guard !topChildren.isEmpty else { return nil }

        // A show's children are usually seasons, but some libraries expose episodes
        // directly. Pick the pool of episodes accordingly.
        let episodes: [MediaItem]
        if topChildren.contains(where: { $0.kind == .episode }) {
            episodes = topChildren.filter { $0.kind == .episode }
        } else if let season = SeriesResume.nextUp(in: topChildren) {
            episodes = ((try? await provider.children(of: season.id)) ?? [])
                .filter { $0.kind == .episode }
        } else {
            episodes = []
        }

        guard let episode = SeriesResume.nextUp(in: episodes) else { return nil }
        // Raw provider children may not carry the owning account; stamp it so
        // `bestSourcePlayItem` and the player target the correct server.
        var stamped = episode
        if stamped.sourceAccountID == nil { stamped.sourceAccountID = series.sourceAccountID }
        return stamped
    }
}
#endif
