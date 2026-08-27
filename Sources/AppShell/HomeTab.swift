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

/// What a ``HomeTab`` stack is rooted at.
///
/// The rail promotes libraries to **top-level destinations**, so a library grid has
/// to be a stack root (chrome visible, nothing to go Back to) rather than a page
/// pushed on top of Home. Rather than duplicate the ~500 lines of detail/person/
/// episode destinations, `HomeTab` takes its root as data: everything below the
/// root — navigation, playback, deep links, the cross-server picker — is shared
/// verbatim, so a library opened from Home and one opened from the rail can never
/// drift apart.
enum HomeTabRoot {
    case home
    /// One library's grid.
    case library(MediaLibrary)
    /// The combined grid over every browsable library the profile can see.
    case allLibraries([AggregatedLibrary])
}

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
struct HomeTab: View {
    /// The app's effective language, injected by `AppLanguageScope`. Read here
    /// only to hand to the Top Shelf publisher: that snapshot crosses into
    /// another process, so its titles have to be resolved on this side.
    @Environment(\.locale) private var locale
    @Environment(\.mediaItemActionHandler) private var mediaItemActionHandler
    /// The rail's chrome model, present only under ``NavigationStyle/rail``. This
    /// stack reports its depth so the rail steps aside on a detail page.
    @Environment(NavigationChromeModel.self) private var navigationChrome: NavigationChromeModel?
    /// What this stack is rooted at: `.home` for the Home destination, a library
    /// for one of the rail's library slots.
    var root: HomeTabRoot = .home
    let accounts: [ResolvedAccount]
    /// Every server added to the device, regardless of what this profile has
    /// switched on. Home needs it to tell "no servers yet" from "all off".
    let configuredServerCount: Int
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
    /// Per-profile Home snapshot store (stable-row paint + fresh volatile rows).
    /// Same lifecycle as `homeLayoutStore`.
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
    /// The identity index's publish counter, handed to the cross-server browse so a
    /// running merge re-folds when the index grows. Defaulted so previews/tests can
    /// omit it.
    var identityRevision: @Sendable () -> Int = { 0 }
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
    /// Whether this tab is the one on screen.
    ///
    /// Replaces a tab-gated `Binding(get:set:)` that used to be synthesised per
    /// evaluation. That binding was non-comparable — SwiftUI cannot prove two
    /// closure-backed bindings equal — so it could never skip this view's body,
    /// and a device capture showed exactly that: `_pendingPersonRoute,
    /// _pendingTitleRoute changed` reported 1,399 times with no `@self`, i.e. the
    /// view value was never rebuilt yet the body re-ran anyway, dragging Home and
    /// any pushed detail page with it at display refresh rate.
    ///
    /// A `Bool` and a plain `@State` binding are both comparable, so an unchanged
    /// pass is now genuinely skippable. The tab gate moves into the handlers,
    /// which is where it was always doing its real work: only the visible tab may
    /// consume a pending route, so the hidden one never pushes the same page.
    let isActiveTab: Bool

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

    /// The stack's root screen, chosen by ``root``. Home, one library's grid, or the
    /// combined grid over every library — all three sit under the same set of
    /// pushed destinations below.
    @ViewBuilder
    private var rootContent: some View {
        switch root {
        case .home:
            homeRoot
        case let .library(library):
            libraryBrowse(for: library)
        case let .allLibraries(libraries):
            allLibrariesBrowse(libraries)
        }
    }

    private var homeRoot: some View {
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
                        mediaItemActionHandler: mediaItemActionHandler,
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
                    identitySources: identitySources,
                    ratingsProvider: ratingsProvider
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
                },
                configuredServerCount: configuredServerCount,
                enabledServerCount: accounts.count
            )
    }

    /// One library's paged grid. Shared by the pushed `MediaLibrary` destination
    /// and — under the rail — by the stack root, so a library looks and behaves the
    /// same however it was opened.
    private func libraryBrowse(for library: MediaLibrary) -> some View {
        let browse = resolveLibraryBrowse(
            for: library,
            in: accounts,
            identitySources: identitySources,
            identityRevision: identityRevision
        )
        return LibraryBrowseView(
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

    /// The combined "All Libraries" grid. Falls back to an unavailable state if no
    /// source resolves (every account signed out mid-flight), which is the only way
    /// the aggregate can end up with nothing to page.
    @ViewBuilder
    private func allLibrariesBrowse(_ libraries: [AggregatedLibrary]) -> some View {
        if let provider = resolveAllLibrariesBrowse(
            libraries: libraries,
            in: accounts,
            identitySources: identitySources,
            identityRevision: identityRevision
        ) {
            LibraryBrowseView(
                viewModel: LibraryBrowseViewModel(
                    provider: provider,
                    // The aggregate ignores the container id (each source carries its
                    // own), but the kind still keys the remembered sort — so this grid
                    // gets its own key rather than sharing one with real libraries.
                    containerID: AllLibrariesBrowse.containerID,
                    containerKind: .unknown,
                    sortKeySuffix: AllLibrariesBrowse.sortKeySuffix,
                    sourceAccountID: nil
                ),
                title: Text(AllLibrariesBrowse.title),
                spoilerSettings: spoilerSettings,
                onSelect: { navigate($0) }
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text(AllLibrariesBrowse.emptyTitle)
                } icon: {
                    Image(systemName: "square.stack.3d.up.slash")
                }
            } description: {
                Text(AllLibrariesBrowse.emptyMessage)
            }
        }
    }

    var body: some View {
        let _ = plozzPrintChanges { Self._printChanges() }
        let _ = PlozzBodyRate.tick("HomeTab")
        NavigationStack(path: $path) {
            rootContent
            .navigationDestination(for: MediaLibrary.self) { library in
                libraryBrowse(for: library)
            }
            .navigationDestination(for: MediaItem.self) { item in
                // Home/Search rows: cross-server-merged, so the detail picker
                // defaults to the smart best version (no library origin).
                itemDetail(for: item, libraryOrigin: nil)
            }
            .onChange(of: pendingTitleRoute) { _, item in
                guard isActiveTab, let item else { return }
                pendingTitleRoute = nil
                path.append(item)
            }
            .onChange(of: pendingPersonRoute) { _, route in
                // Raised by the in-player Cast card and pushed once the player
                // has gone. Cleared immediately so the same person can be
                // opened again later — and so the other tab, which watches the
                // same value, never sees it.
                guard isActiveTab, let route else { return }
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
                        relatedTitlesLoader: makeRelatedTitlesLoader(
                            in: accounts,
                            identitySources: identitySources
                        ),
                        snapshotCache: detailSnapshotCache
                    ) },
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    onNavigate: { navigate($0, asOwnSubject: $0.kind == .episode) },
                    onSelectPerson: { person, accountID in
                        path.append(PersonRoute(person: person, sourceAccountID: accountID))
                    },
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
                        relatedTitlesLoader: makeRelatedTitlesLoader(
                            in: accounts,
                            identitySources: identitySources
                        ),
                        snapshotCache: detailSnapshotCache
                    ) },
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0, libraryOrigin: route.originAccountID) },
                    onNavigate: { navigate($0, asOwnSubject: $0.kind == .episode) },
                    onSelectPerson: { person, accountID in
                        path.append(PersonRoute(person: person, sourceAccountID: accountID))
                    },
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
        // Under the rail, a pushed page is a detail page — report the depth so the
        // chrome steps aside and the title page is full-bleed. No-op under the two
        // native tab styles, which install no chrome model.
        .reportsNavigationDepth(path.count, to: navigationChrome)
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
                isActive: isActiveTab,
                // Open the title's page, then start it. Playing straight from the
                // shelf left the viewer on Home the moment they backed out — the
                // title they had just been watching nowhere in sight, and no way
                // to reach its episodes or its description without finding it
                // again. Pushing first means Back lands somewhere that makes
                // sense, and costs nothing on the way in: the player is presented
                // over the stack, so the page is simply already there underneath.
                onResolved: { item in
                    navigate(item)
                    // Next runloop turn, so the push is committed before the
                    // player is presented over it. Presenting into a navigation
                    // change that is still settling drops the cover on tvOS.
                    Task { @MainActor in
                        await Task.yield()
                        requestPlay(item)
                    }
                }
            )
            ScreenshotRouter(
                director: runtime.screenshotDirector,
                accounts: accounts,
                isActive: isActiveTab,
                onHome: {
                    // The player is presented over the stack, not pushed onto
                    // it, so emptying the path leaves it up — and every request
                    // after a `play` then photographs the still-running video.
                    playRequest = nil
                    resumePrompt = nil
                    path = NavigationPath()
                },
                onPush: { path.append($0) },
                // Straight to the player, NOT through `requestPlay`: an item
                // with progress raises the Resume/Start Over prompt, and a
                // capture of the player is then a capture of that alert.
                //
                // A series still has to be resolved to an episode first. Series
                // and seasons are containers with no media of their own, so
                // handing one to the player answers "Can't play this right now"
                // — which is exactly what a shot of a show's player looked like
                // until this went through the same next-up resolver Play uses.
                onPlay: { item, seconds in
                    let target = bestSourcePlayItem(
                        item, accounts: accounts, identitySources: identitySources
                    )
                    guard target.kind.needsPlaybackTargetResolution else {
                        playRequest = PlayRequest(item: target, startPosition: seconds)
                        return
                    }
                    Task { @MainActor in
                        guard let episode = await resolveSeriesNextUpEpisode(target) else { return }
                        playRequest = PlayRequest(
                            item: bestSourcePlayItem(
                                episode, accounts: accounts, identitySources: identitySources
                            ),
                            startPosition: seconds
                        )
                    }
                }
            )
        }
    }

    /// Performs the capture rig's screen requests. A leaf for the same reason as
    /// ``DeepLinkPlayRouter``: reading the request in `HomeTab.body` would
    /// subscribe the whole tab to it, so every request would rebuild the
    /// navigation stack and every pushed page.
    ///
    /// Each request is resolved by *searching the real library* for the named
    /// title and pushing the value a tap would have pushed, so the resulting
    /// screen is the same one a person would reach — only reached by name
    /// instead of by counting remote presses.
    private struct ScreenshotRouter: View {
        let director: ScreenshotDirector
        let accounts: [ResolvedAccount]
        let isActive: Bool
        let onHome: () -> Void
        let onPush: (any Hashable) -> Void
        let onPlay: (MediaItem, Double) -> Void

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                // Active state is part of identity so a request that arrived while
                // this tab was hidden runs when the tab becomes visible.
                .task(id: RouteRequest(
                    request: director.request,
                    isActive: isActive
                )) { await perform() }
        }

        private struct RouteRequest: Equatable {
            let request: ScreenshotDirector.Request?
            let isActive: Bool
        }

        private func perform() async {
            guard isActive else { return }
            guard let request = director.request else { return }
            director.request = nil
            director.finish(await reach(request))
        }

        /// Reaches the requested screen and answers with what the capture script
        /// should see in the ack. Returns text rather than an enum so a probe can
        /// answer with the titles it found; every other request answers `ok` or
        /// `notFound`.
        private func reach(_ request: ScreenshotDirector.Request) async -> String {
            switch request {
            case .home:
                await popToRoot()

            case let .detail(title):
                guard let item = await find(title) else { return notFound }
                await popToRoot()
                onPush(route(for: item))

            case let .person(title, name):
                guard let item = await find(title) else { return notFound }
                await popToRoot()
                onPush(route(for: item))
                // The cast list belongs to the *detail* page's fetch, so read
                // the person off the item's own credits rather than waiting on
                // the page to render one.
                guard let person = await person(named: name, in: item) else { return notFound }
                await settlePush()
                onPush(PersonRoute(person: person, sourceAccountID: item.sourceAccountID))

            case let .library(name, sort):
                guard let library = await library(named: name) else { return notFound }
                applySort(sort)
                await popToRoot()
                onPush(library)

            case let .play(title, seconds, panel, pause, subtitles):
                guard let item = await find(title) else { return notFound }
                await popToRoot()
                // Set before the play so the player finds it already waiting;
                // the player is built by the request below.
                PlayerScreenshotHook.pendingPanel =
                    panel.flatMap(PlayerScreenshotHook.Panel.init(rawValue:))
                ScreenshotSeed.pausesPlayback = pause
                ScreenshotSeed.pendingPlayerSeek = pause ? seconds : nil
                // The subtitle track is picked while the player loads, so the
                // mode has to be settled *and observed* before the request goes
                // out — hence the settle. Setting it in the same turn as
                // `onPlay` handed the player the previous shot's value.
                ScreenshotSeed.setSubtitleMode?(subtitles ? .all : .off)
                await settlePush()
                // Starting partway in is what puts real progress in the scrubber
                // and real artwork behind the overlay — a shot taken at 0:00 is a
                // black frame under a full-width empty bar.
                onPlay(item, seconds)

            case let .probe(title):
                var found: [String] = []
                for resolved in accounts {
                    guard let results = try? await resolved.provider.search(query: title, limit: 25)
                    else { continue }
                    found.append(contentsOf: results.map { "\($0.title) [\($0.kind.rawValue)]" })
                }
                return found.isEmpty ? notFound : found.joined(separator: "\n")
            }
            return ScreenshotDirector.Outcome.ok.rawValue
        }

        private var notFound: String { ScreenshotDirector.Outcome.notFound.rawValue }

        /// Points the library grid at a named ``SortField`` before it opens.
        ///
        /// The browse view model reads its sort from `UserDefaults` when it is
        /// built, so setting the key here takes effect on the push that follows.
        /// Left alone when no sort is asked for, so a run never quietly
        /// rearranges a library that was opened by hand.
        private func applySort(_ field: String?) {
            guard let field, let sortField = SortField(rawValue: field) else { return }
            let descriptor = SortDescriptor(
                field: sortField,
                direction: sortField == .name ? .ascending : .descending
            )
            guard let data = try? JSONEncoder().encode(descriptor) else { return }
            for kind in [MediaItemKind.movie, .series] {
                UserDefaults.standard.set(data, forKey: "LibraryBrowse.sort.\(kind.rawValue)")
            }
        }

        /// Empties the stack and lets the pop finish.
        ///
        /// Resetting the path and appending to it in the same runloop turn nets
        /// out to no change at all as far as `NavigationStack` is concerned: the
        /// second capture run photographed the *first* title four times over,
        /// because every later request popped and pushed within one turn and the
        /// stack never noticed it had been asked to go anywhere. Separating them
        /// by a turn — and giving the pop transition time to land — is what makes
        /// each request actually move the stack.
        private func popToRoot() async {
            onHome()
            await settlePush()
        }

        private func settlePush() async {
            try? await Task.sleep(for: .milliseconds(700))
        }

        /// The value `navigate` would append for `item` — kept in step with it
        /// so a captured page is the page a tap opens, not a near neighbour.
        private func route(for item: MediaItem) -> any Hashable {
            if item.kind == .episode, item.seriesID != nil {
                return EpisodeContextRoute(episode: item, originAccountID: nil)
            }
            if item.kind == .season, item.seriesID != nil {
                return SeasonContextRoute(season: item, originAccountID: nil)
            }
            return item
        }

        /// The best match for `title` across every signed-in account.
        ///
        /// Searched by shortening rather than by the full title, because a full
        /// title is often the one query that fails. Asking the share catalog for
        /// "The Lord of the Rings: The Fellowship of the Ring" returns nothing,
        /// while "Lord of the Rings" returns all four films — long queries with
        /// punctuation fall through whatever tokenisation it does. So the query
        /// is shortened a word at a time until something comes back, and the
        /// *full* requested title is then matched against those results.
        ///
        /// That ordering matters: shortening only widens what is searched, and
        /// the exact match still decides, so "Mario" cannot come back as a
        /// documentary about Mario Puzo when the requested film exists.
        private func find(_ title: String) async -> MediaItem? {  // l10n:content — a media title from the server
            var fallback: MediaItem?
            for query in Self.queries(for: title) {
                for resolved in accounts {
                    guard let results = try? await resolved.provider.search(query: query, limit: 40),
                          !results.isEmpty
                    else { continue }
                    let tagged = results.map { $0.taggingSource(resolved.account.id) }
                    if let exact = tagged.first(where: {
                        $0.title.compare(title, options: .caseInsensitive) == .orderedSame
                    }) {
                        return exact
                    }
                    fallback = fallback ?? tagged.first
                }
            }
            return fallback
        }

        /// The full title, then progressively shorter leading phrases, down to
        /// one word.
        ///
        /// Every level is tried even after one of them returns results, because
        /// returning *something* is not the same as returning the right thing:
        /// stopping at the first non-empty level answered "Dune: Part Two" with
        /// whatever the two-word query "Dune: Part" happened to surface. Only an
        /// exact title match short-circuits.
        private static func queries(for title: String) -> [String] {  // l10n:content — a media title from the server
            let words = title.split(separator: " ").map(String.init)
            guard words.count > 1 else { return [title] }
            var seen = Set<String>()
            return (1...words.count)
                .reversed()
                .map { words.prefix($0).joined(separator: " ") }
                // Trailing punctuation has to go or the shortening does nothing
                // useful: "Dune: Part Two" shortens to "Dune:", and the catalog
                // answers that with nothing while the bare "Dune" finds it.
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " :-,.")) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        private func person(named name: String, in item: MediaItem) async -> MediaPerson? {
            let provider = resolveProvider(item.sourceAccountID, in: accounts)
            let detailed = (try? await provider.item(id: item.id)) ?? item
            let cast = detailed.cast.isEmpty ? detailed.people : detailed.cast
            return cast.first {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            } ?? cast.first { $0.name.localizedCaseInsensitiveContains(name) }
        }

        private func library(named name: String?) async -> MediaLibrary? {
            for resolved in accounts {
                guard let libraries = try? await resolved.provider.libraries(),
                      !libraries.isEmpty
                else { continue }
                guard let name else { return libraries.first }
                if let match = libraries.first(where: {
                    $0.title.localizedCaseInsensitiveContains(name)
                }) {
                    return match
                }
            }
            return nil
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
        let isActive: Bool
        let onResolved: (MediaItem) -> Void

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                // Keyed on the accounts as well as the id. A launch straight from a
                // Top Shelf card delivers the link before any provider exists, so a
                // task watching only the id runs once, against nothing, and never
                // again — the app opens and sits there, which is exactly what the
                // shelf looked like from the sofa.
                .task(id: RouteRequest(
                    itemID: pendingPlay.itemID,
                    accountID: pendingPlay.accountID,
                    accountIDs: accounts.map(\.account.id),
                    isActive: isActive
                )) { await route() }
        }

        /// What a routing attempt depends on. Any change re-runs it.
        private struct RouteRequest: Equatable {
            let itemID: String?
            let accountID: String?
            let accountIDs: [String]
            let isActive: Bool
        }

        private func route() async {
            guard isActive else { return }
            guard let id = pendingPlay.itemID else { return }
            // Nothing to ask yet. Deliberately keeps the request pending: accounts
            // arriving is a change this task is watching, so it will run again with
            // something to resolve against.
            guard !accounts.isEmpty else { return }

            // The link's own account first, when it named one — it is the server the
            // card was built from, so it is both the fastest answer and the only one
            // guaranteed to mean the same title.
            let ordered: [ResolvedAccount]
            if let owner = pendingPlay.accountID,
               let match = accounts.first(where: { $0.account.id == owner }) {
                ordered = [match] + accounts.filter { $0.account.id != owner }
            } else {
                ordered = accounts
            }

            for resolved in ordered {
                if let item = try? await resolved.provider.item(id: id) {
                    // Another run may have resolved it while this one was waiting:
                    // the task restarts whenever the accounts change, and a request
                    // already in flight is not stopped by that. Acting twice pushes
                    // the page twice and presents the player over itself.
                    guard pendingPlay.itemID == id else { return }
                    pendingPlay.itemID = nil
                    pendingPlay.accountID = nil
                    onResolved(item.taggingSource(resolved.account.id))
                    return
                }
            }
            // Only an uninterrupted sweep may declare the title gone. A cancelled
            // one asked nobody: the fetch above cannot tell being cancelled apart
            // from a server saying no, so a task restarted mid-flight would fall
            // through here and discard a request that no server ever answered —
            // landing the viewer on Home, which is the whole thing this fixes.
            guard !Task.isCancelled else { return }
            // Asked every signed-in server and none of them knows it. Clearing stops
            // a title that has genuinely gone from re-asking on every account change
            // for the rest of the session.
            pendingPlay.itemID = nil
            pendingPlay.accountID = nil
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
            makeRelatedTitlesLoader: {
                makeRelatedTitlesLoader(
                    in: accounts,
                    identitySources: identitySources,
                    displayMode: $0
                )
            },
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
        // A series OR season can't be direct-played (the container has no media,
        // so `playbackInfo` for its ratingKey returns notFound). Resolve the
        // next-up / resume EPISODE and play that — matching Apple TV's hero Play.
        // If we can't resolve an episode (e.g. the show isn't really in the library
        // or the fetch fails), fall back to opening the detail page.
        if target.kind.needsPlaybackTargetResolution {
            Task { @MainActor in
                if let episode = await resolveSeriesNextUpEpisode(target) {
                    presentPlay(
                        bestSourcePlayItem(
                            episode,
                            accounts: accounts,
                            identitySources: identitySources
                        )
                    )
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
