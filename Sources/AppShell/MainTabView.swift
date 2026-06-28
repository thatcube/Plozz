#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService

/// Bundles the watch-outbox interactions the full-screen player needs: live-
/// session registration (so the convergence reconciler defers writes against the
/// server currently streaming) plus the durable final convergence enqueue. Passed
/// down the tab hierarchy in place of a bare enqueue closure so the player can
/// both guard and converge through one value.
struct WatchOutboxBridge: Sendable {
    /// Register `(accountID, itemID)` as the live in-app session (idempotent).
    let beginLiveSession: @Sendable (_ accountID: String, _ itemID: String) -> Void
    /// End the live session for `(accountID, itemID)` and enqueue the optional
    /// final convergence `mutation`, in that order, so the just-played server is
    /// no longer deferred and its resume/played write goes out. `watchedPercent`
    /// (0...100) is the fraction watched at stop, used to drive the optimistic
    /// in-UI progress update (the resume bar on the surface the user returns to).
    let finishPlayback: @Sendable (_ accountID: String?, _ itemID: String, _ watchedPercent: Double, _ mutation: WatchMutation?) -> Void
    /// Durably enqueue a mid-play convergence `mutation` without ending the live
    /// session, so progress fans out to the **other** servers (the launch server
    /// stays deferred while it plays). Pure local enqueue + drain — no network on
    /// the caller's path.
    let checkpoint: @Sendable (_ mutation: WatchMutation) -> Void
    /// Live, off-main read of the active profile's "sync watch state across
    /// servers" preference, evaluated at stop/checkpoint time (not captured at
    /// player start) so flipping the toggle mid-playback takes effect on the next
    /// convergence. Backed by a thread-safe UserDefaults read.
    let crossServerSync: @Sendable () -> Bool
}

/// The signed-in experience: Home, Search and Settings tabs, with item-detail
/// navigation and full-screen playback.
///
/// Home and Search are **unified across every active account/provider** via the
/// aggregation seam (`[ResolvedAccount]`). Each merged item/library is tagged
/// with its owning account so a tapped result routes to the correct provider.
/// Settings exposes account management, the customizable Home-libraries
/// checklist, and caption/spoiler/theme settings.
struct MainTabView: View {
    let accounts: [ResolvedAccount]
    let captionModel: CaptionSettingsModel
    let spoilerModel: SpoilerSettingsModel
    let playbackModel: PlaybackSettingsModel
    let themeModel: ThemeSettingsModel
    let diagnosticsModel: DiagnosticsSettingsModel
    let musicPlayerModel: MusicPlayerSettingsModel
    /// Per-profile UI density, injected into the environment below so the
    /// Settings ▸ Appearance picker can edit it.
    let uiDensityModel: UIDensitySettingsModel
    /// App-scoped audio engine, owned by `AppState` so it survives the per-profile
    /// subtree rebuild (this view is re-created with a new `.id` on profile switch).
    let audioController: AudioPlaybackController
    let homeVisibility: HomeLibraryVisibilityModel
    /// Per-profile store for the last-rendered Home row structure, used to seed
    /// the loading skeleton so it matches the user's real Home before content
    /// arrives. Constructed with the active profile's namespace by `RootView`.
    let homeLayoutStore: HomeLayoutStoring
    let ratingsProvider: any ExternalRatingsProviding
    let trakt: TraktService
    let mediaItemActionHandler: any MediaItemActionHandling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    let displayAccounts: [Account]
    let activeAccountID: String?
    let profiles: [Profile]
    let activeProfile: Profile
    let askProfileOnStartup: Bool
    let profilesEnabled: Bool
    @Binding var pendingPlayItemID: String?
    let isAccountIncludedInActiveProfile: (String) -> Bool
    let onSetAccountIncluded: (String, Bool) -> Void
    let onSetAskProfileOnStartup: (Bool) -> Void
    let onEnableProfiles: () -> Void
    let onDisableProfiles: () -> Void
    let onSaveProfile: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    let onSignOutAll: () -> Void
    let onSwitchProfile: () -> Void
    let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void
    /// The shared source-of-truth lookup: a title → its full cross-server source
    /// set from the eager identity index. Threaded into Home/Search/Browse merging,
    /// the detail picker and the watch fan-out so all read one consistent set.
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Kicks off (or incrementally refreshes) the identity index for the signed-in
    /// accounts. Invoked when the signed-in UI appears.
    let onWarmIdentityIndex: () -> Void

    @State private var discovery = LibraryDiscoveryModel()
    @State private var musicAvailability = MusicAvailabilityModel()
    @Environment(\.colorScheme) private var systemColorScheme

    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(for: themeModel.theme, systemColorScheme: systemColorScheme)
    }

    var body: some View {
        TabView {
            HomeTab(
                accounts: accounts,
                homeVisibility: homeVisibility,
                homeLayoutStore: homeLayoutStore,
                captionSettings: captionModel.settings,
                playbackSettings: playbackModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                scrobbler: trakt.scrobbler,
                enqueueWatchMutation: enqueueWatchMutation,
                watchBridge: watchBridge,
                identitySources: identitySources,
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SearchTab(
                accounts: accounts,
                captionSettings: captionModel.settings,
                playbackSettings: playbackModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                scrobbler: trakt.scrobbler,
                enqueueWatchMutation: enqueueWatchMutation,
                watchBridge: watchBridge,
                identitySources: identitySources
            )
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            // Conditional Music tab: present only when at least one signed-in
            // account exposes a music library. Video-only users see no tab and no
            // mini-player — the app is byte-for-byte unchanged for them.
            if musicAvailability.hasMusic {
                MusicTabView(
                    accounts: musicAvailability.detectedAccounts,
                    visibleLibraryIDs: musicAvailability.visibleLibraryIDs,
                    controller: audioController,
                    appTheme: themeModel.theme,
                    musicPlayer: musicPlayerModel
                )
                .tabItem { Label("Music", systemImage: "music.note") }
            }

            SettingsView(
                captions: captionModel,
                spoilers: spoilerModel,
                playback: playbackModel,
                theme: themeModel,
                homeVisibility: homeVisibility,
                trakt: trakt,
                discoveredLibraries: discovery.state,
                reloadLibraries: { await discovery.load(from: accounts) },
                accounts: displayAccounts,
                activeAccountID: activeAccountID,
                profiles: profiles,
                activeProfile: activeProfile,
                askProfileOnStartup: askProfileOnStartup,
                profilesEnabled: profilesEnabled,
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                repoURL: AppInfo.repoURLString,
                isAccountIncludedInActiveProfile: isAccountIncludedInActiveProfile,
                onSetAccountIncluded: onSetAccountIncluded,
                onSetAskProfileOnStartup: onSetAskProfileOnStartup,
                onEnableProfiles: onEnableProfiles,
                onDisableProfiles: onDisableProfiles,
                onSwitchProfile: onSwitchProfile,
                onSaveProfile: onSaveProfile,
                onDeleteProfile: onDeleteProfile,
                onAddAccount: onAddAccount,
                onRemoveAccount: onRemoveAccount,
                onSignOutAll: onSignOutAll,
                plexHomeUsersFetcher: plexHomeUsersFetcher,
                onSelectPlexHomeUser: onSelectPlexHomeUser
            )
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environment(musicPlayerModel)
        .environment(uiDensityModel)
        .task(id: accounts.map(\.account.id)) {
            onWarmIdentityIndex()
        }
        .task(id: musicProbeKey) {
            // Paint the Music tab on the first frame from the last persisted
            // result (synchronous, no network) so tab visibility never waits on
            // a probe. Re-runs when accounts or the per-profile library toggles
            // change, so hiding/showing a music library live re-evaluates the tab.
            musicAvailability.seedFromCache(accounts: accounts, visibility: homeVisibility.visibility)
        }
        .task(id: musicProbeKey, priority: .utility) {
            // Everything network-bound runs at LOW priority and out of the
            // critical launch window so the Home page (movies/TV) — the first
            // thing the user sees — always wins the launch network/CPU. The
            // synchronous seed above already shows the tab; the probe only
            // refreshes its presence, so it can afford to yield.
            await musicAvailability.probe(accounts: accounts, visibility: homeVisibility.visibility)
            guard musicAvailability.hasMusic else { return }
            // Defer the heavy multi-account landing prefetch until after Home has
            // had the launch window. The Music tab still opens instantly from this
            // warm cache once the user gets there; if they open it sooner,
            // MusicLandingView's own load() fetches on demand (and caches) anyway.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, musicAvailability.hasMusic else { return }
            await MusicLandingPrefetch.warm(
                accounts: musicAvailability.detectedAccounts,
                visibleLibraryIDs: musicAvailability.visibleLibraryIDs
            )
        }
        .mediaItemActionHandler(mediaItemActionHandler)
    }

    /// Restarts the music probe whenever the signed-in accounts or the per-profile
    /// library-visibility toggles change.
    private var musicProbeKey: String {
        let ids = accounts.map(\.account.id).sorted()
        let excluded = homeVisibility.visibility.excludedKeys.sorted()
        return (ids + ["|"] + excluded).joined(separator: ",")
    }
}

/// Resolves the provider that owns `accountID`, falling back to the primary
/// (first) account for untagged items. `accounts` is guaranteed non-empty by the
/// caller (`RootView`).
private func resolveProvider(_ accountID: String?, in accounts: [ResolvedAccount]) -> any MediaProvider {
    if let accountID, let match = accounts.first(where: { $0.account.id == accountID }) {
        return match.provider
    }
    return accounts[0].provider
}

/// Resolves a specific account id to its provider, or `nil` when that account is
/// no longer signed in. Used by the detail page to fetch a merged title's
/// *alternate* servers' versions/watch-state for the server picker — a missing
/// account simply drops that source rather than falling back to another server.
private func resolveOptionalProvider(_ accountID: String, in accounts: [ResolvedAccount]) -> (any MediaProvider)? {
    accounts.first(where: { $0.account.id == accountID })?.provider
}

/// Builds the detail page's cross-server source resolver: given the title the
/// user opened, it searches every *other* signed-in account, merges the hits with
/// the primary by ``MediaItemIdentity`` (the same safe identity rules the Home /
/// Search dedupe use), and returns the unified per-server ``MediaSourceRef`` list.
/// The matching is **by provider IDs**, so a copy stored under a *different title*
/// on another server still collapses into the picker — see
/// ``CrossServerSourceResolver`` (which also widens the search with a normalized
/// title so that differently-annotated copy is actually returned to be matched).
///
/// This is what makes the **server picker appear from Home** even when only one
/// server surfaced the title in its row (Recently Added / Continue Watching are
/// per-server, so a Home card often starts single-source) — Search already shows
/// both servers because it queries them all, and now the detail page does the
/// same discovery on open. Returns `nil` for a single-account setup (nothing to
/// discover), which keeps the resolver entirely off the path for solo servers.
/// Runs a provider search but gives up after `seconds`, returning whatever it
/// has (empty on timeout). A cold/slow/unreachable server otherwise makes the
/// whole cross-server discovery fan-out wait for its full request timeout — that
/// straggler keeps the discovery task (and its cooperative-pool work) alive long
/// after the user has moved on, contributing to next-page starvation.
///
/// The deadline is driven by a **libdispatch timer**, not `Task.sleep`. Under the
/// very pool saturation this guard exists to relieve, a `Task.sleep`-based
/// timeout cannot fire — its continuation needs a cooperative-pool thread that
/// the backlog is holding — so the race silently waits the full server timeout
/// (observed: a 33s Plex search that should have been cut at 4s). A
/// `DispatchQueue.asyncAfter` fires on its own dispatch thread regardless of
/// pool state and cancels the search task, which aborts the in-flight URLSession
/// request and frees its connection on schedule.
private func searchWithDeadline(
    _ provider: any MediaProvider,
    query: String,
    limit: Int,
    seconds: Double
) async -> [MediaItem] {
    let searchTask = Task { (try? await provider.search(query: query, limit: limit)) ?? [] }
    let timeout = DispatchWorkItem { searchTask.cancel() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
    let result = await searchTask.value
    timeout.cancel()
    return result
}

private func crossServerSourceResolver(
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> (@Sendable (MediaItem) async -> [MediaSourceRef])? {
    guard !accounts.isEmpty else { return nil }
    let serverInfo = accounts.sourceServerInfo()
    let providersByAccountID: [String: any MediaProvider] = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { primary in
        // Start from the eager index's known sources for this title — the shared
        // source of truth — so the picker is at least as complete as the watch
        // fan-out even before (or without) an on-demand probe.
        var sources: [MediaSourceRef] = identitySources(primary)
        var seen = Set(sources.map(\.id))
        // Probe EVERY signed-in account, including the primary's own. The
        // primary's own item id is filtered inside the resolver so same-server
        // duplicate movie items (two Jellyfin items, one film) group into one
        // detail with a multi-entry version picker — without this only OTHER
        // servers' twins were discovered and a same-server duplicate was invisible.
        let everyAccount = Array(providersByAccountID.keys)
        let resolved = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: everyAccount,
            search: { accountID, query in
                guard let provider = providersByAccountID[accountID] else { return [] }
                return await searchWithDeadline(provider, query: query, limit: 25, seconds: 4)
            },
            serverInfo: { serverInfo[$0] }
        )
        // The on-demand probe carries live versions/watch-state, so let it win on
        // id collisions: drop index placeholders the probe already covered, then
        // union in any index-only server the probe missed.
        let resolvedIDs = Set(resolved.map(\.id))
        sources.removeAll { resolvedIDs.contains($0.id) }
        seen = resolvedIDs
        var merged = resolved
        for ref in sources where seen.insert(ref.id).inserted { merged.append(ref) }
        return merged
    }
}

/// Builds the provider that backs a Library-browse grid for `library`. When the
/// Home aggregator merged the same library across several servers
/// (`allSourceAccountIDs.count > 1`) it returns an ``AggregatedLibraryProvider``
/// that pages and de-duplicates every server's copy into one grid (criterion 1
/// for Library browse); otherwise it returns the single owning provider. The
/// returned `sourceAccountID` is `nil` for the aggregated case so the browse
/// view-model doesn't re-tag items and clobber their per-source identity.
private func resolveLibraryBrowse(
    for library: MediaLibrary,
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> (provider: any MediaProvider, sourceAccountID: String?) {
    let accountIDs = library.allSourceAccountIDs
    if accountIDs.count > 1 {
        let sources: [AggregatedLibrarySource] = accountIDs.compactMap { accountID in
            guard
                let provider = resolveOptionalProvider(accountID, in: accounts),
                let containerID = library.containerID(forSourceAccountID: accountID)
            else { return nil }
            return AggregatedLibrarySource(accountID: accountID, containerID: containerID, provider: provider)
        }
        if sources.count > 1 {
            return (
                AggregatedLibraryProvider(
                    sources: sources,
                    serverInfo: accounts.sourceServerInfo(),
                    identitySources: identitySources
                ),
                nil
            )
        }
        // Only one source still resolves (others signed out): browse it directly.
        if let only = sources.first {
            return (only.provider, only.accountID)
        }
    }
    return (resolveProvider(library.sourceAccountID, in: accounts), library.sourceAccountID)
}

/// Builds the player for a play request. Online (TMDb → YouTube) trailers carry a
/// YouTube video-id marker and have no backing account, so they are routed to
/// ``YouTubeTrailerProvider`` (which extracts a playable stream); every other
/// item resolves through its owning account provider as usual.
@MainActor
private func makePlayerViewModel(
    for request: PlayRequest,
    accounts: [ResolvedAccount],
    captionSettings: CaptionSettings,
    playbackSettings: PlaybackSettings,
    scrobbler: any TraktScrobbling,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> PlayerViewModel {
    if let videoID = request.item.youTubeTrailerVideoID {
        let trailerItem = request.item
        let onlineTrailerResolver = ItemDetailViewModel.defaultOnlineTrailerResolver
        let engineFactory = HybridPlayback.engineFactory()
        return PlayerViewModel(
            provider: YouTubeTrailerProvider(
                item: trailerItem,
                videoID: videoID,
                alternatives: {
                    // The server's stored trailer URL can go stale (the YouTube
                    // video gets made private/removed). When that happens, fall
                    // back to a keyless search for a still-playable replacement
                    // trailer for the same title.
                    let results = await onlineTrailerResolver(
                        trailerItem.alternativeTrailerSearchSubject
                    )
                    return results.compactMap(\.youTubeTrailerVideoID)
                },
                // Only resolve the higher-resolution adaptive (separate audio)
                // path when a hybrid engine is wired in to mux the two tracks.
                allowsSeparateAudio: engineFactory.hybridAvailable
            ),
            itemID: videoID,
            captionSettings: captionSettings,
            playbackSettings: playbackSettings,
            startPosition: request.startPosition,
            scrobbler: scrobbler,
            engineFactory: engineFactory,
            autoDismissOnEnd: true
        )
    }
    // Capture only Sendable value types / closures for the durable convergence hook
    // so it can run off the main actor when the player stops. The eager identity
    // lookup itself is resolved at stop time, after the shared index has had the
    // full playback window to warm.
    let convergingItem = request.item
    let primaryAccountID = accounts.first?.account.id
    // The live session key must match the origin target the factory derives for
    // the streaming server, so the reconciler defers writes against exactly that
    // (account,item) while it plays. `sourceAccountID` falls back to the primary
    // account for single-source items, mirroring WatchMutationFactory.targets(for:).
    let liveAccountID = request.item.sourceAccountID ?? primaryAccountID
    let liveItemID = request.item.id
    return PlayerViewModel(
        provider: resolveProvider(request.item.sourceAccountID, in: accounts),
        itemID: request.item.id,
        mediaSourceID: request.item.selectedVersionID,
        captionSettings: captionSettings,
        playbackSettings: playbackSettings,
        startPosition: request.startPosition,
        scrobbler: scrobbler,
        engineFactory: HybridPlayback.engineFactory(),
        onPlaybackStopped: makePlaybackStoppedHandler(
            convergingItem: convergingItem,
            primaryAccountID: primaryAccountID,
            liveAccountID: liveAccountID,
            liveItemID: liveItemID,
            watchBridge: watchBridge,
            identitySources: identitySources
        ),
        onPlaybackStarted: {
            // Guard the streaming server while it plays: a mid-play drain can't
            // disturb/zero its now-playing session. Deferred, not dropped.
            if let liveAccountID {
                watchBridge.beginLiveSession(liveAccountID, liveItemID)
            }
        },
        onPlaybackCheckpoint: makePlaybackCheckpointHandler(
            convergingItem: convergingItem,
            primaryAccountID: primaryAccountID,
            watchBridge: watchBridge,
            identitySources: identitySources
        )
    )
}

/// Builds the periodic mid-play convergence hook. Mirrors
/// ``makePlaybackStoppedHandler`` but **enqueue-only**: it does NOT end the live
/// session (the launch server keeps playing/deferred) and does NOT publish an
/// optimistic UI flip (the user is in the fullscreen player). Its sole job is to
/// fan the latest position out to the **other** servers so a "walk away" mid-movie
/// converges within ~60s without pressing Back.
func makePlaybackCheckpointHandler(
    convergingItem: MediaItem,
    primaryAccountID: String?,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void {
    { position, percent in
        let union = identitySources(convergingItem)
        let mutation = WatchMutationFactory.playbackStop(
            item: convergingItem,
            position: position,
            watchedPercent: percent,
            primaryAccountID: primaryAccountID,
            additionalSources: union,
            crossServerSync: watchBridge.crossServerSync()
        )
        guard let mutation else { return }
        FanoutDiagnostics.emit(FanoutDiagnostics.stopLine(
            title: convergingItem.title,
            kind: convergingItem.kind,
            itemID: convergingItem.id,
            originAccountID: convergingItem.sourceAccountID ?? primaryAccountID,
            identities: MediaItemIdentity.identities(for: convergingItem),
            indexUnion: union,
            mutationTargets: mutation.targets,
            played: mutation.played,
            resumePosition: mutation.resumePosition,
            watchedPercent: percent,
            phase: "checkpoint"
        ))
        watchBridge.checkpoint(mutation)
    }
}

func makePlaybackStoppedHandler(
    convergingItem: MediaItem,
    primaryAccountID: String?,
    liveAccountID: String?,
    liveItemID: String,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void {
    { position, percent in
        let union = identitySources(convergingItem)
        let mutation = WatchMutationFactory.playbackStop(
            item: convergingItem,
            position: position,
            watchedPercent: percent,
            primaryAccountID: primaryAccountID,
            additionalSources: union,
            crossServerSync: watchBridge.crossServerSync()
        )
        // (b)+(c) Make the stop event visible: the played item's resolved identity,
        // the index union found for it, and the final mutation target set. Pure
        // string building + fire-and-forget os_log — never delays the durable write.
        FanoutDiagnostics.emit(FanoutDiagnostics.stopLine(
            title: convergingItem.title,
            kind: convergingItem.kind,
            itemID: convergingItem.id,
            originAccountID: convergingItem.sourceAccountID ?? primaryAccountID,
            identities: MediaItemIdentity.identities(for: convergingItem),
            indexUnion: union,
            mutationTargets: mutation?.targets,
            played: mutation?.played,
            resumePosition: mutation?.resumePosition,
            watchedPercent: percent
        ))
        // End the live session (so the just-played server is no longer deferred)
        // and enqueue the final convergence write, in that order. `percent` rides
        // along so the surface the user returns to can flip its resume bar in place.
        watchBridge.finishPlayback(liveAccountID, liveItemID, percent, mutation)
    }
}

/// Hosts the full-screen player and builds its ``PlayerViewModel`` exactly once,
/// off the render path.
///
/// Constructing the view model inline inside a `.fullScreenCover` content closure
/// is a trap: SwiftUI re-invokes that closure on every parent render, and because
/// ``PlayerView`` keeps the model in `@State` (the first value wins), every extra
/// invocation builds a throwaway `PlayerViewModel` — and a throwaway
/// `NativeVideoEngine` at its `init` — that is discarded immediately. Under the
/// player's own `@Observable` mutation churn this becomes self-reinforcing: each
/// render spawns engines that storm `AttributeGraph`, which drives more renders.
/// On device this showed up as the live VM/Native instance counters racing
/// upward (Native far ahead of VM, since every model makes a native engine before
/// it ever routes to mpv), thermal throttling, and growing lag the longer the
/// player stayed up.
///
/// Building the model in `.task`, gated by this view's identity, fires the factory
/// once per presentation instead of once per render.
@MainActor
private struct PlayerPresentation: View {
    let request: PlayRequest
    let make: (PlayRequest) -> PlayerViewModel
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    @State private var viewModel: PlayerViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: showDiagnostics,
                    themePalette: themePalette
                )
            }
        }
        .task {
            if viewModel == nil {
                viewModel = make(request)
            }
        }
    }
}

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
private struct HomeTab: View {
    let accounts: [ResolvedAccount]
    let homeVisibility: HomeLibraryVisibilityModel
    let homeLayoutStore: HomeLayoutStoring
    let captionSettings: CaptionSettings
    let playbackSettings: PlaybackSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding
    let scrobbler: any TraktScrobbling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    @Binding var pendingPlayItemID: String?

    @State private var path = NavigationPath()
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: HomeViewModel(
                    accounts: accounts,
                    layoutStore: homeLayoutStore,
                    identitySources: identitySources,
                    currentVisibility: { homeVisibility.visibility }
                ),
                visibility: homeVisibility,
                spoilerSettings: spoilerSettings,
                onSelectItem: { navigate($0) },
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
                    onSelect: { navigate($0, libraryOrigin: browse.sourceAccountID) }
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
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does —
                        // discovery matches the series by provider IDs and fills
                        // the server list once the page settles.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0) },
                    initialEpisode: route.episode
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
                        // The fronted page IS the series, so it gets the same
                        // cross-server "…" picker a directly-opened series does.
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0) },
                    initialSeasonID: route.season.id
                )
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerPresentation(
                request: request,
                make: {
                    makePlayerViewModel(
                        for: $0,
                        accounts: accounts,
                        captionSettings: captionSettings,
                        playbackSettings: playbackSettings,
                        scrobbler: scrobbler,
                        watchBridge: watchBridge,
                        identitySources: identitySources
                    )
                },
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
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
    /// default. Episode/season routes do no cross-server discovery (no picker), so
    /// they need not carry the origin — they already play from their own provider.
    private func navigate(_ item: MediaItem, libraryOrigin: String? = nil) {
        if item.kind == .episode, item.seriesID != nil {
            path.append(EpisodeContextRoute(episode: item))
        } else if item.kind == .season, item.seriesID != nil {
            path.append(SeasonContextRoute(season: item))
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
        ItemDetailView(
            viewModel: ItemDetailViewModel(
                provider: resolveProvider(item.sourceAccountID, in: accounts),
                itemID: item.id,
                initialItem: item,
                ratingsProvider: ratingsProvider,
                sourceAccountID: item.sourceAccountID,
                originSourceAccountID: libraryOrigin,
                initialSources: item.sources,
                alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                snapshotCache: .shared
            ),
            spoilerSettings: spoilerSettings,
            onPlay: { requestPlay($0) },
            onSelectChild: { navigate($0, libraryOrigin: libraryOrigin) },
            initialSeasonID: item.seasonID
        )
    }

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        if let resume = item.resumePosition, resume > 1 {
            resumePrompt = item
        } else {
            playRequest = PlayRequest(item: item, startPosition: 0)
        }
    }
}

/// A fully-resolved request to present the player for an item at an explicit
/// start position (seconds). `startPosition` of `0` means "start over".
private struct PlayRequest: Identifiable, Equatable {
    let item: MediaItem
    let startPosition: TimeInterval
    var id: String { item.id }
}

/// A navigation value for opening an item's detail page **from a library tile**,
/// carrying the library's owning `Account.id` so the detail/playback default to
/// that server's copy (the cross-server picker still lets the user switch). Home
/// and Search push the bare ``MediaItem`` instead, which keeps the smart
/// best-version default.
private struct LibraryDetailRoute: Hashable {
    let item: MediaItem
    /// The owning `Account.id` of the library this item was opened from, or `nil`
    /// when the origin can't be resolved (then the detail falls back to best).
    let originAccountID: String?
}

/// A navigation value for opening a *series* page focused on one of its
/// episodes. Tapping a lone episode (e.g. from "Recently Added") routes through
/// this instead of pushing the episode itself, so the user always lands on the
/// rich series/season page — with the tapped episode fronted in the hero, its
/// season selected, the episode row pre-scrolled to it, and Play focused at the
/// top — rather than a dead-end single-episode page.
private struct EpisodeContextRoute: Hashable {
    let episode: MediaItem
    /// The owning series' id (falls back to the episode id only if unset, which
    /// shouldn't happen for an episode that carries a `seriesID`).
    var seriesID: String { episode.seriesID ?? episode.id }
    var sourceAccountID: String? { episode.sourceAccountID }
}

/// A navigation value for opening a *series* page focused on a specific season.
/// Tapping a season item (e.g. from "Recently Added") routes through this instead
/// of pushing the season itself, so the user always lands on the rich series page —
/// with the tapped season selected, and the "next up" episode for that season
/// fronted in the hero.
private struct SeasonContextRoute: Hashable {
    let season: MediaItem
    /// The owning series' id.
    var seriesID: String { season.seriesID ?? season.id }
    var sourceAccountID: String? { season.sourceAccountID }
}

private extension View {
    /// Presents a "Resume vs Start Over" choice for an in-progress `item`.
    /// `onChoose` receives the chosen start position in seconds (the saved
    /// resume point for Resume, `0` for Start Over).
    func resumePrompt(
        item: Binding<MediaItem?>,
        onChoose: @escaping (MediaItem, TimeInterval) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { presented in
            // Resume is listed first so it receives default focus.
            Button("Resume from \(PlaybackTimecode.string(from: presented.resumePosition ?? 0))") {
                onChoose(presented, presented.resumePosition ?? 0)
            }
            Button("Start Over") {
                onChoose(presented, 0)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Search tab with its own navigation stack: Search → Detail and full-screen
/// player presentation, mirroring `HomeTab`'s wiring. Search is aggregated
/// across every active account; results route to their owning provider.
private struct SearchTab: View {
    let accounts: [ResolvedAccount]
    let captionSettings: CaptionSettings
    let playbackSettings: PlaybackSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding
    let scrobbler: any TraktScrobbling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]

    @State private var path = NavigationPath()
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(
                viewModel: SearchViewModel(accounts: accounts, identitySources: identitySources),
                spoilerSettings: spoilerSettings,
                onSelect: { open($0) }
            )
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(item.sourceAccountID, in: accounts),
                        itemID: item.id,
                        initialItem: item,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: item.sourceAccountID,
                        initialSources: item.sources,
                        alternateProviderResolver: { resolveOptionalProvider($0, in: accounts) },
                        crossServerSourceResolver: crossServerSourceResolver(in: accounts, identitySources: identitySources),
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialSeasonID: item.seasonID
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
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialEpisode: route.episode
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
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialSeasonID: route.season.id
                )
            }
        }
        .mediaItemNavigator { item in
            if item.kind == .episode, item.seriesID != nil {
                path.append(EpisodeContextRoute(episode: item))
            } else if item.kind == .season, item.seriesID != nil {
                path.append(SeasonContextRoute(season: item))
            } else {
                path.append(item)
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerPresentation(
                request: request,
                make: {
                    makePlayerViewModel(
                        for: $0,
                        accounts: accounts,
                        captionSettings: captionSettings,
                        playbackSettings: playbackSettings,
                        scrobbler: scrobbler,
                        watchBridge: watchBridge,
                        identitySources: identitySources
                    )
                },
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
    }

    /// Selecting a search result always opens its detail page rather than
    /// playing immediately; episodes/seasons route through their series context
    /// so the detail page has the surrounding show, mirroring `mediaItemNavigator`.
    private func open(_ item: MediaItem) {
        switch item.kind {
        case .episode where item.seriesID != nil:
            path.append(EpisodeContextRoute(episode: item))
        case .season where item.seriesID != nil:
            path.append(SeasonContextRoute(season: item))
        default:
            path.append(item)
        }
    }

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        if let resume = item.resumePosition, resume > 1 {
            resumePrompt = item
        } else {
            playRequest = PlayRequest(item: item, startPosition: 0)
        }
    }
}

#endif
