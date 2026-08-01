#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHome
import FeatureHomeCore
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
import TopShelfKit

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
struct HomeTab: View {
    /// The app's effective language, injected by `AppLanguageScope`. Read here
    /// only to hand to the Top Shelf publisher: that snapshot crosses into
    /// another process, so its titles have to be resolved on this side.
    @Environment(\.locale) private var locale
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
    /// Lets Home poke the media shares while the viewer sits on it.
    let onPollShares: () -> Void
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
    /// A person page raised by the in-player Cast card, to push once the player
    /// has closed. Non-nil only while THIS tab is the one on screen, so the two
    /// tabs that observe it can never both push the same page.
    @Binding var pendingPersonRoute: PersonRoute?
    /// A title raised by the in-player Cast card, pushed once the player has
    /// closed. Non-nil only while THIS tab is on screen — see the person route.
    @Binding var pendingTitleRoute: MediaItem?

    @State private var path = NavigationPath()
    /// Handles owned above the tab so tab re-hosting cannot destroy them.
    let runtime: HomeTabRuntime
    /// Detail view models, kept across `navigationDestination` re-evaluations.
    /// Those closures re-run on every render pass while their page is on the
    /// stack, and `ItemDetailView` keeps only the first value in `@State` — so
    /// building one inline meant constructing and discarding a view model (and
    /// re-resolving the item's cross-server sources) several times per push.
    @State private var detailViewModels = KeyedViewStateCache<String, ItemDetailViewModel>()
    /// Person view models, cached for the same reason as `detailViewModels`: the
    /// destination closure re-runs on every render pass, so building one inline
    /// constructs and discards a model (and re-issues its credits fetch) on each.
    @State private var personViewModels = KeyedViewStateCache<String, PersonDetailViewModel>()
    /// Lets a detail page tell whether a child page is pushed on top of it.
    /// See `DetailStackDepth`.
    @State private var detailStackDepth = DetailStackDepth()

    /// Resolves only a FAST hero trailer: a real local/server extra from any
    /// cross-server copy. Online YouTube ids are deliberately rejected on Home.
    private func makeHeroTrailerResolver() -> HeroTrailerResolving {
        { item in
            await FastHeroTrailerResolver.resolve(
                item: item,
                identitySources: identitySources(item),
                providerForAccountID: {
                    resolveOptionalProvider($0, in: accounts)
                },
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
        }
    }

    var body: some View {
        let _ = plozzPrintChanges { Self._printChanges() }
        NavigationStack(path: $path) {
            HomeView(
                viewModel: runtime.homeViewModel.value(forKey: runtime.scopeKey) {
                    HomeViewModel(
                        accounts: accounts,
                        layoutStore: homeLayoutStore,
                        contentStore: homeContentStore,
                        identitySources: identitySources,
                        currentVisibility: { homeVisibility.visibility },
                        pendingWatchMutations: pendingWatchMutations,
                        recentlyAppliedRecency: appliedWatchRecency,
                        contentPublisher: { continueWatching, latest in
                            await TopShelfPublisher.publish(
                                continueWatching: continueWatching,
                                latest: latest,
                                locale: locale
                            )
                        }
                    )
                },
                visibility: homeVisibility,
                spoilerSettings: spoilerSettings,
                heroSettings: heroSettings,
                heroBackground: heroBackground,
                heroTrailerController: heroTrailerController,
                onPollShares: onPollShares,
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
                onRequestAvailability: { await seer.requestAvailability(for: $0) },
                onRequestSeasonsItem: { item, seasons in
                    let outcome = await seer.request(item, seasons: seasons, actingUserID: activeSeerrUserID)
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
                    let item = $0
                    Task { @MainActor in
                        await heroTrailerController.captureHandoffFrame()
                        if heroTrailerController.isShowing(item.id),
                           heroTrailerController.isPlaying {
                            // A system NavigationStack push snapshots/composites
                            // the newly-created detail hierarchy before its video
                            // layer is live, which exposes a backdrop for a few
                            // frames. A playing hero trailer is a visual continuity
                            // handoff, not a spatial page move: atomically replace
                            // only the foreground metadata. Pop remains animated.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                navigate(item)
                            }
                        } else {
                            navigate(item)
                        }
                    }
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
                    title: library.displayName,
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
            .onChange(of: pendingTitleRoute) { _, item in
                guard let item else { return }
                pendingTitleRoute = nil
                path.append(item)
            }
            .onChange(of: pendingPersonRoute) { _, route in
                // Raised by the in-player Cast card and pushed once the player
                // has gone. Cleared immediately so the same person can be
                // opened again later — and so the other tab, which watches the
                // same value, never sees it.
                guard let route else { return }
                pendingPersonRoute = nil
                path.append(route)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(
                    person: route.person,
                    viewModel: personViewModels.value(
                        forKey: "person:\(route.person.id)#\(route.sourceAccountID ?? "")"
                    ) {
                        PersonDetailViewModel(
                            person: route.person,
                            // The person's own source, never the cross-server
                            // aggregate: credits are answered with that server's
                            // own person id, and a bare id isn't unique across
                            // servers.
                            // `resolveOptionalProvider`, never
                            // `resolveProvider`: the latter falls back to the
                            // primary account, which sent Jellyfin and share
                            // person ids to Plex and got nothing back. No
                            // account means no credits, not wrong credits.
                            provider: route.sourceAccountID.flatMap {
                                resolveOptionalProvider($0, in: accounts)
                            },
                            // Every OTHER signed-in server, asked by name because
                            // person ids don't cross servers. Empty for the
                            // single-server case, where this stays one request.
                            otherProviders: accounts
                                .filter { $0.account.id != route.sourceAccountID }
                                .map(\.provider),
                            // Only reached when no server stored a biography.
                            // Wikipedia needs no key or account, so this rung
                            // works for every user out of the box.
                            biographyProviders: [WikipediaPersonBiographyProvider()],
                            // The same ladder the in-player Cast card uses, and
                            // for the same reason: without it this page can only
                            // answer with what the viewer already owns, which is
                            // not what "known for" means.
                            //
                            // TMDb leads where a key is available — it alone
                            // knows how prominent a person was in a title rather
                            // than only how famous the title is. Wikidata and
                            // TVmaze are keyless and carry the rest.
                            creditsProviders: PlayerCastCredits.providers,
                            // Artwork only, applied after ranking. Never a
                            // ranking input: letting the source with the best
                            // artwork reach further down the row was measured
                            // making the order worse.
                            artworkResolver: PlayerCastCredits.artworkResolver,
                            // So a credit the viewer owns isn't marked absent:
                            // a server's person query only returns titles whose
                            // own People list names the person, and a series
                            // records its main cast rather than a guest voice
                            // part — so owned shows arrive from TMDb flagged
                            // `.unknown` with nothing else able to tell.
                            librarySources: identitySources
                        )
                    },
                    onSelectItem: { navigate($0, libraryOrigin: route.sourceAccountID) }
                )
            }
            .navigationDestination(for: LibraryDetailRoute.self) { route in
                // Opened from a library tile: default detail + playback to THAT
                // library's server (the picker still lets the user switch).
                itemDetail(for: route.item, libraryOrigin: route.originAccountID)
            }
            .navigationDestination(for: EpisodeContextRoute.self) { route in
                ItemDetailView(
                    viewModel: detailViewModels.value(
                        forKey: "episode:\(route.seriesID)#\(route.episode.id)"
                    ) { ItemDetailViewModel(
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
                        relatedTitlesLoader: makeRelatedTitlesLoader(in: accounts),
                        snapshotCache: detailSnapshotCache
                    ) },
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    onNavigate: { navigate($0, asOwnSubject: $0.kind == .episode) },
                    stackDepth: detailStackDepth,
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
                    viewModel: detailViewModels.value(
                        forKey: "season:\(route.seriesID)#\(route.season.id)"
                    ) { ItemDetailViewModel(
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
                        relatedTitlesLoader: makeRelatedTitlesLoader(in: accounts),
                        snapshotCache: detailSnapshotCache
                    ) },
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    onNavigate: { navigate($0, asOwnSubject: $0.kind == .episode) },
                    stackDepth: detailStackDepth,
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
            // Installed *inside* the stack, after the destinations, so pushed
            // pages inherit it too. Applied outside the `NavigationStack` it only
            // reaches the root content — "Episode Info" worked on Continue
            // Watching and was silently dropped in every pushed detail page.
            .mediaItemNavigator { navigate($0, asOwnSubject: $0.kind == .episode) }
        }
        // The deep-link watcher lives in its own leaf view. Reading the pending
        // id in *this* body subscribed the whole tab to it, and every publish
        // re-ran `HomeTab.body` — 1,619 times in 50s on device while the id
        // never left `nil` — rebuilding the navigation stack and every pushed
        // destination's view model each pass, until the watchdog killed the app.
        // The leaf reads it and renders nothing, so the invalidation is free.
        .background {
            DeepLinkPlayRouter(
                pendingPlay: runtime.pendingPlay,
                accounts: accounts,
                onResolved: { requestPlay($0) }
            )
        }
    }

    /// Resolves a deep-linked item id (from a Top Shelf card) and routes to it,
    /// then clears the request so it fires exactly once. Because the id alone is
    /// provider-ambiguous once content is merged, each active provider is tried
    /// until one resolves the item; the resolved item is tagged with its source.
    ///
    /// Lives on ``DeepLinkPlayRouter`` rather than on the tab so that watching
    /// the pending id cannot invalidate the tab's body.
    private struct DeepLinkPlayRouter: View {
        let pendingPlay: PendingPlayRequest
        let accounts: [ResolvedAccount]
        let onResolved: (MediaItem) -> Void

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task(id: pendingPlay.itemID) { await route() }
        }

        private func route() async {
            guard let id = pendingPlay.itemID else { return }
            pendingPlay.itemID = nil
            for resolved in accounts {
                if let item = try? await resolved.provider.item(id: id) {
                    onResolved(item.taggingSource(resolved.account.id))
                    return
                }
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
    /// Routes a navigation to `item`.
    ///
    /// `asOwnSubject` distinguishes the two ways an episode can be navigated to.
    /// A menu's "Episode Info" wants the episode's *own* page — its synopsis, air
    /// date, and the file that would play. Everything else that hands over an
    /// episode (a deep link, a tapped card) means "show me this episode in
    /// context", which is the series page with it fronted.
    private func navigate(
        _ item: MediaItem,
        libraryOrigin: String? = nil,
        asOwnSubject: Bool = false
    ) {
        if item.kind == .episode, asOwnSubject {
            path.append(item)
        } else if item.kind == .episode, item.seriesID != nil {
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
    /// The shared detail-open environment built from this tab's app model. Every
    /// detail-open destination constructs its view model through this one factory
    /// (see ``DetailOpenEnvironment``) instead of hand-rolling
    /// `ItemDetailViewModel(...)`, so the item→viewModel glue can't drift.
    private var detailEnvironment: DetailOpenEnvironment {
        let accounts = self.accounts
        let identitySources = self.identitySources
        let seer = self.seer
        return DetailOpenEnvironment(
            resolveProvider: { resolveProvider($0, in: accounts) },
            resolveOptionalProvider: { resolveOptionalProvider($0, in: accounts) },
            identitySources: identitySources,
            crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
            ratingsProvider: ratingsProvider,
            discoveryStatusRefresh: { await seer.availability(for: $0) },
            makeRelatedTitlesLoader: { makeRelatedTitlesLoader(in: accounts) },
            snapshotCache: detailSnapshotCache
        )
    }

    private func itemDetail(for item: MediaItem, libraryOrigin: String?) -> some View {
        // A discovery (Seerr) title that isn't in the library — e.g. a "More Info"
        // tap on a *not-owned* featured hero slide — routes to the request-focused
        // discovery detail page instead of a doomed library fetch. Owned featured
        // titles (available/partiallyAvailable) are NOT discovery: they resolve to
        // a real library copy via the identity index, so they keep the normal
        // playable detail page.
        let isDiscovery = detailEnvironment.isDiscovery(item)
        return ItemDetailView(
            viewModel: detailViewModels.value(forKey: "item:\(item.id)#\(libraryOrigin ?? "")") {
                detailEnvironment.makeViewModel(for: item, libraryOrigin: libraryOrigin)
            },
            spoilerSettings: spoilerSettings,
            onPlay: { requestPlay($0) },
            onSelectChild: { navigate($0, libraryOrigin: libraryOrigin) },
            onNavigate: { navigate($0, asOwnSubject: $0.kind == .episode) },
            onSelectPerson: { person, accountID in
                path.append(PersonRoute(person: person, sourceAccountID: accountID))
            },
            stackDepth: detailStackDepth,
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

    /// Resolves a series to the episode Play should start, via the shared
    /// resolver both shells use, so tvOS and iOS front the same episode and a
    /// series can never reach the player on either platform.
    private func resolveSeriesNextUpEpisode(_ series: MediaItem) async -> MediaItem? {
        await HeroPlayTargetResolver.playbackTarget(
            for: series,
            provider: resolveProvider(series.sourceAccountID, in: accounts)
        )
    }
}
#endif
