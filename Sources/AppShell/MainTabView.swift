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
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

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

/// Real-time scrobble fan-out injected into the player. Conforms to
/// `TraktScrobbling` (the type the player expects) but forwards every
/// start/pause/stop event to **both** Trakt and Simkl so each shows "Now
/// Watching" the instant playback begins. Other trackers (MAL/AniList) have no
/// real-time now-watching API, so they continue to converge on stop via the
/// durable watch-state outbox. Best-effort: errors never reach playback.
struct RealtimePlaybackScrobbler: TraktScrobbling {
    let trakt: any TraktScrobbling
    let simkl: any SimklScrobbling

    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        await trakt.scrobble(item: item, progress: progress, event: event)
        await simkl.scrobble(item: item, progress: progress, event: event)
    }
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
    /// Stable identifiers for the root tabs, used to persist and restore the
    /// selected tab across MainTabView being rebuilt (see `selectedTab`).
    private enum MainTab: String {
        case home, search, music, settings
    }

    let accounts: [ResolvedAccount]
    /// Subtitle behaviour (mode / language / auto-download) and appearance
    /// (`SubtitleStyle`) split out of the retired `CaptionSettings`. Behaviour
    /// feeds the policy resolver; style seeds the player + live overlay.
    let subtitleBehaviorModel: SubtitleBehaviorModel
    let subtitleStyleModel: SubtitleStyleModel
    let spoilerModel: SpoilerSettingsModel
    let playbackModel: PlaybackSettingsModel
    /// Per-profile per-content-type subtitle policy overrides, threaded into the
    /// player (resolved against the caption base) and into Settings for editing.
    let subtitlePolicyModel: SubtitlePolicyModel
    /// Per-profile per-content-type audio-language overrides, threaded into the
    /// player (resolved against the playback base) and into Settings for editing.
    let audioPolicyModel: AudioPolicyModel
    let themeModel: ThemeSettingsModel
    /// Per-profile remembered per-series audio/subtitle selections, threaded into
    /// the player so a manual track switch sticks across that show's episodes.
    let seriesTrackStore: any SeriesTrackPreferenceStoring
    let diagnosticsModel: DiagnosticsSettingsModel
    /// App-wide, opt-in crash-reporting consent (off by default). Threaded into
    /// Settings ▸ Help & Diagnostics so the household can turn it on/off.
    let crashReportingModel: CrashReportingSettingsModel
    /// Whether this build has a crash-reporting endpoint baked in; drives whether
    /// the opt-in toggle is enabled or shown disabled with a note.
    let crashReportingConfigured: Bool
    let musicPlayerModel: MusicPlayerSettingsModel
    /// Per-profile UI density, injected into the environment below so the
    /// Settings ▸ Appearance picker can edit it.
    let uiDensityModel: UIDensitySettingsModel
    /// Per-profile media card style, edited in Settings ▸ Appearance ▸ Display.
    /// Injected into the environment for the Settings editor; card rendering reads
    /// `\.plozzCardStyle` (installed at the app root in RootView).
    let cardStyleModel: CardStyleSettingsModel
    /// Per-profile watch-status indicator (a "watched" check badge vs an
    /// "unwatched" corner flag), edited in Settings ▸ Appearance ▸ Display.
    /// Injected into the environment for the Settings editor; card rendering reads
    /// `\.plozzWatchStatusIndicator` (installed at the app root in RootView).
    let watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel
    /// Per-profile navigation chrome (top bar vs. sidebar), edited in Settings ▸
    /// Appearance ▸ Display. This view reads its `style` to pick the `TabViewStyle`;
    /// the Settings editor binds the model, and chrome-sensitive views elsewhere
    /// read `\.plozzNavigationStyle` (installed at the app root in RootView).
    let navigationStyleModel: NavigationStyleSettingsModel
    /// Per-profile transparency (liquid glass) preference, edited in Settings ▸
    /// Appearance ▸ Display. Injected into the environment for the Settings editor;
    /// the resolved value drives `\.plozzReduceTransparency` (installed in RootView).
    let transparencyModel: TransparencyPreferenceModel
    /// Per-profile Home hero (featured carousel) settings, edited in
    /// Settings ▸ Home display. Threaded into `HomeTab` to drive the carousel and
    /// into Settings for editing.
    let heroSettingsModel: HeroSettingsModel
    /// App-wide media-share scan/enrich status, injected into the environment so
    /// Home shows an "Updating library…" banner and Settings shows last-scanned.
    let shareScanStatusModel: ShareScanStatusModel
    /// Per-profile Night Shift settings, edited in Settings ▸ Night Shift. Its
    /// overlay is installed at the app root (RootView); here it's only threaded
    /// into Settings for editing.
    let nightShiftModel: NightShiftSettingsModel
    /// App-scoped audio engine, owned by `AppState` so it survives the per-profile
    /// subtree rebuild (this view is re-created with a new `.id` on profile switch).
    let audioController: AudioPlaybackController
    let homeVisibility: HomeLibraryVisibilityModel
    /// Per-profile store for the last-rendered Home row structure, used to seed
    /// the loading skeleton so it matches the user's real Home before content
    /// arrives. Constructed with the active profile's namespace by `RootView`.
    let homeLayoutStore: HomeLayoutStoring
    /// Per-profile store for the last successful Home content snapshot, so the hero
    /// + Continue Watching (and the rest of Home) paint instantly on launch and
    /// then silently refresh. Constructed with the active profile's namespace by
    /// `RootView` (same lifecycle as `homeLayoutStore`).
    let homeContentStore: HomeContentStoring
    let ratingsProvider: any ExternalRatingsProviding
    let trakt: TraktService
    let simkl: SimklService
    let seer: SeerService
    let anilist: AniListService
    let mal: MALService
    let lastfm: LastFmService
    let mediaItemActionHandler: any MediaItemActionHandling
    let enqueueWatchMutation: (WatchMutation) -> Void
    let watchBridge: WatchOutboxBridge
    /// Snapshot of the durable outbox's not-yet-confirmed plays, so Home's Continue
    /// Watching row reflects in-app plays the servers haven't recorded yet
    /// (r8-cw-outbox-patch).
    let pendingWatchMutations: @Sendable () async -> [WatchMutation]
    /// Recently-applied in-progress resume writes, so Home's Continue Watching row
    /// can clamp a server's drain-time timestamp inflation back down to the real
    /// play time (h2-cw-clamp).
    let appliedWatchRecency: @Sendable () async -> [String: AppliedResumeRecord]
    let displayAccounts: [Account]
    let activeAccountID: String?
    /// The active profile's included-account set, threaded as a value so the
    /// Settings toggles that read it re-render when a server is switched on/off.
    let activeAccountIDs: Set<String>
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
    /// Live cosmetics-only persistence for editing an existing profile (see
    /// `AppState.updateProfileCosmetics`), so the editor can auto-save.
    let onUpdateProfileCosmetics: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    let onRescanShare: (String) -> Void
    let onSignOutAll: () -> Void
    let onSwitchProfile: () -> Void
    let onResetToFirstRun: () -> Void
    let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void
    /// Maps a household profile to a Seerr user (or clears it) — forwarded to the
    /// Settings "requests are made as" list.
    var onSetSeerrUser: (String, SeerUser?) -> Void = { _, _ in }
    /// The shared source-of-truth lookup: a title → its full cross-server source
    /// set from the eager identity index. Threaded into Home/Search/Browse merging,
    /// the detail picker and the watch fan-out so all read one consistent set.
    let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Kicks off (or incrementally refreshes) the identity index for the signed-in
    /// accounts. Invoked when the signed-in UI appears.
    let onWarmIdentityIndex: () -> Void

    @State private var discovery = LibraryDiscoveryModel()
    /// Owns the Settings library-discovery result as an `@Observable` reference so
    /// that a reload (which fires on Settings appearance, DURING the tab focus-flip)
    /// only re-renders the library detail pages that read it — never the Settings
    /// ROOT list. Threading the raw `LoadState` value through `SettingsView`
    /// instead rebuilt the root rows mid-flip → `setToViewXFlippedScreenShot:` UAF.
    @State private var librariesStore = DiscoveredLibrariesStore()
    @State private var musicAvailability = MusicAvailabilityModel()
    /// Hosts the full-screen Now Playing player as a `fullScreenCover` on the root
    /// TabView rather than inside the Music tab's navigation stack — the latter
    /// presents unreliably under the sidebar tab style (the cover only appears
    /// after a stray Back press). Bound down into `MusicTabView`, which flips it.
    @State private var showNowPlaying = false
    /// The video player is hosted here on the root `TabView` (not inside a tab's
    /// navigation stack) so it presents reliably on the FIRST trigger — the same
    /// reason `showNowPlaying` lives here. A `fullScreenCover` attached inside a
    /// NavigationStack presents a beat late (only after a stray Back press), which
    /// is why playing from deep in a media-share folder tree only fired once the
    /// user backed all the way out to Home. HomeTab/SearchTab write these bindings.
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?
    @Environment(\.colorScheme) private var systemColorScheme

    /// The selected root tab, persisted so it survives MainTabView being torn
    /// down and rebuilt — e.g. the add-server flow swaps the whole root out for
    /// the onboarding chooser, and on return we want to land back on the tab the
    /// user left from (usually Settings), not reset to Home.
    @SceneStorage("mainTab.selection") private var selectedTabRaw = MainTab.home.rawValue

    private var selectedTab: Binding<MainTab> {
        Binding(
            get: { MainTab(rawValue: selectedTabRaw) ?? .home },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    private var navigationStyle: NavigationStyle {
        navigationStyleModel.style
    }

    private var resolvedPalette: ThemePalette {
        // `systemColorScheme` here is the scheme RootView pushed down via
        // `.environment(\.colorScheme,)` — for `.system` that equals the real
        // device scheme, so Settings' theme switching follows the device.
        ThemePalette.palette(for: themeModel.theme, systemColorScheme: systemColorScheme)
    }

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
            HomeTab(
                accounts: accounts,
                seer: seer,
                activeSeerrUserID: activeProfile.seerrUserID,
                activeSeerrUserName: activeProfile.seerrUserName,
                confirmAdminRequest: profiles.count > 1,
                homeVisibility: homeVisibility,
                homeLayoutStore: homeLayoutStore,
                homeContentStore: homeContentStore,
                heroSettings: heroSettingsModel,
                navigationStyle: navigationStyle,
                behavior: subtitleBehaviorModel.settings,
                style: subtitleStyleModel.style,
                playbackSettings: playbackModel.settings,
                subtitlePolicy: subtitlePolicyModel.resolvedPolicy(behavior: subtitleBehaviorModel.settings),
                audioPolicy: audioPolicyModel.resolvedPolicy(settings: playbackModel.settings),
                seriesTrackStore: seriesTrackStore,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                scrobbler: RealtimePlaybackScrobbler(trakt: trakt.scrobbler, simkl: simkl.scrobbler),
                enqueueWatchMutation: enqueueWatchMutation,
                watchBridge: watchBridge,
                identitySources: identitySources,
                pendingPlayItemID: $pendingPlayItemID,
                pendingWatchMutations: pendingWatchMutations,
                appliedWatchRecency: appliedWatchRecency,
                onSubtitleStyleChanged: { subtitleStyleModel.style = $0 },
                playRequest: $playRequest,
                resumePrompt: $resumePrompt
            )
            }

            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search) {
            SearchTab(
                accounts: accounts,
                seer: seer,
                activeSeerrUserID: activeProfile.seerrUserID,
                activeSeerrUserName: activeProfile.seerrUserName,
                confirmAdminRequest: profiles.count > 1,
                homeVisibility: homeVisibility,
                behavior: subtitleBehaviorModel.settings,
                style: subtitleStyleModel.style,
                playbackSettings: playbackModel.settings,
                subtitlePolicy: subtitlePolicyModel.resolvedPolicy(behavior: subtitleBehaviorModel.settings),
                audioPolicy: audioPolicyModel.resolvedPolicy(settings: playbackModel.settings),
                seriesTrackStore: seriesTrackStore,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                scrobbler: RealtimePlaybackScrobbler(trakt: trakt.scrobbler, simkl: simkl.scrobbler),
                enqueueWatchMutation: enqueueWatchMutation,
                watchBridge: watchBridge,
                identitySources: identitySources,
                onSubtitleStyleChanged: { subtitleStyleModel.style = $0 },
                playRequest: $playRequest,
                resumePrompt: $resumePrompt
            )
            }

            // Conditional Music tab: present only when at least one signed-in
            // account exposes a music library. Video-only users see no tab and no
            // mini-player — the app is byte-for-byte unchanged for them.
            if musicAvailability.hasMusic {
                Tab("Music", systemImage: "music.note", value: MainTab.music) {
                MusicTabView(
                    accounts: musicAvailability.detectedAccounts,
                    visibleLibraryIDs: musicAvailability.visibleLibraryIDs,
                    controller: audioController,
                    appTheme: themeModel.theme,
                    musicPlayer: musicPlayerModel,
                    showNowPlaying: $showNowPlaying
                )
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
            SettingsView(
                subtitleBehavior: subtitleBehaviorModel,
                spoilers: spoilerModel,
                playback: playbackModel,
                subtitlePolicy: subtitlePolicyModel,
                audioPolicy: audioPolicyModel,
                theme: themeModel,
                nightShift: nightShiftModel,
                homeVisibility: homeVisibility,
                diagnostics: diagnosticsModel,
                crashReporting: crashReportingModel,
                crashReportingConfigured: crashReportingConfigured,
                trakt: trakt,
                simkl: simkl,
                seer: seer,
                anilist: anilist,
                mal: mal,
                lastfm: lastfm,
                librariesStore: librariesStore,
                reloadLibraries: {
                    // Load OFF the model's own published state (used elsewhere by
                    // SelectLibrariesView) and write results into the store the
                    // Settings detail pages observe. MainTabView never READS
                    // `librariesStore.state`, so this reload can't re-render the
                    // Settings root list during the tab focus-flip.
                    librariesStore.state = .loading
                    let libraries = await discovery.libraries(from: accounts)
                    librariesStore.state = libraries.isEmpty ? .empty : .loaded(libraries)
                },
                accounts: displayAccounts,
                activeAccountID: activeAccountID,
                activeAccountIDs: activeAccountIDs,
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
                onUpdateProfileCosmetics: onUpdateProfileCosmetics,
                onDeleteProfile: onDeleteProfile,
                onAddAccount: onAddAccount,
                onRemoveAccount: onRemoveAccount,
                onRescanShare: onRescanShare,
                onSignOutAll: onSignOutAll,
                onResetToFirstRun: onResetToFirstRun,
                plexHomeUsersFetcher: plexHomeUsersFetcher,
                onSelectPlexHomeUser: onSelectPlexHomeUser,
                onSetSeerrUser: onSetSeerrUser
            )
            }
        }
        .plozzTabStyle(navigationStyle)
        // Host the full-screen Now Playing player here, on the root TabView, so it
        // presents reliably on the first trigger under both tab styles. Hosting it
        // inside the Music tab's navigation stack made it present a beat late under
        // the sidebar style (only appearing after a stray Back press).
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(
                controller: audioController,
                appTheme: themeModel.theme,
                musicPlayer: musicPlayerModel
            )
        }
        // The VIDEO player is hosted here on the root TabView too, for the same
        // first-trigger reliability reason as the music player above. HomeTab and
        // SearchTab set `playRequest` / `resumePrompt`; this presents over the
        // whole shell no matter how deep the active tab's navigation stack is.
        .playerHost(
            playRequest: $playRequest,
            resumePrompt: $resumePrompt,
            accounts: accounts,
            behavior: subtitleBehaviorModel.settings,
            style: subtitleStyleModel.style,
            playbackSettings: playbackModel.settings,
            spoilerSettings: spoilerModel.settings,
            subtitlePolicy: subtitlePolicyModel.resolvedPolicy(behavior: subtitleBehaviorModel.settings),
            audioPolicy: audioPolicyModel.resolvedPolicy(settings: playbackModel.settings),
            seriesTrackStore: seriesTrackStore,
            scrobbler: RealtimePlaybackScrobbler(trakt: trakt.scrobbler, simkl: simkl.scrobbler),
            watchBridge: watchBridge,
            identitySources: identitySources,
            showDiagnostics: diagnosticsModel.settings.isEnabled,
            themePalette: resolvedPalette,
            onSubtitleStyleChanged: { subtitleStyleModel.style = $0 }
        )
        .environment(musicPlayerModel)
        .environment(uiDensityModel)
        .environment(cardStyleModel)
        .environment(watchStatusIndicatorModel)
        .environment(navigationStyleModel)
        .environment(transparencyModel)
        .environment(heroSettingsModel)
        .environment(shareScanStatusModel)
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
    /// **app-wide disabled** libraries change. Music availability keys off the
    /// enabled (disabled) state, not the Home-only "Show on Home" bit, so hiding a
    /// library from Home no longer re-probes Music while disabling it does.
    private var musicProbeKey: String {
        let ids = accounts.map(\.account.id).sorted()
        let disabled = homeVisibility.visibility.disabledKeys.sorted()
        return (ids + ["|"] + disabled).joined(separator: ",")
    }
}

private extension View {
    /// Applies the native tvOS 18 `TabView` presentation matching the user's
    /// `NavigationStyle`. Kept as a `@ViewBuilder` switch (rather than a ternary)
    /// because `.sidebarAdaptable` and `.tabBarOnly` are distinct concrete
    /// `TabViewStyle` types that can't share one expression.
    @ViewBuilder
    func plozzTabStyle(_ style: NavigationStyle) -> some View {
        switch style {
        case .tabBar: self.tabViewStyle(.tabBarOnly)
        case .sidebar: self.tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// Resolves the provider that owns `accountID`, falling back to the primary
/// (first) account. `accounts` is guaranteed non-empty by the caller
/// (`RootView`).
///
/// The fallback is legitimate only for a **nil** `accountID` (a genuinely
/// untagged item — e.g. a route with no owning server — plays from the primary
/// account). A **non-nil but unmatched** `accountID` is different: it means the
/// caller handed an explicit source whose account is no longer signed in, and
/// silently playing it from `accounts[0]` is the "random / wrong server" symptom
/// — you'd stream a *different server's* copy than the one selected. The play
/// paths prune to live accounts first (`bestSourcePlayItem`) so this shouldn't
/// be reached in practice; when it is, emit a (gated) diagnostic so the stale
/// pick is observable on device rather than masquerading as a successful play.
private func resolveProvider(_ accountID: String?, in accounts: [ResolvedAccount]) -> any MediaProvider {
    if let accountID {
        if let match = accounts.first(where: { $0.account.id == accountID }) {
            return match.provider
        }
        FanoutDiagnostics.emit("resolveProvider fallback: explicit account \(accountID) not signed in; using primary \(accounts[0].account.id)")
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

/// Builds the Home hero's Random source fetcher (dual-provider): given a set of
/// concrete `"accountID:libraryID"` keys (already resolved from the user's
/// selection or the visible-library fallback in `HomeView`), it fetches a
/// server-shuffled page from each library — on **both** Jellyfin and Plex, which
/// each map `SortField.random` onto their native random order — and returns a
/// merged, capped pool for the curator to interleave. Each library's child kind
/// is resolved from its owning provider's catalog so the typed random query is
/// issued correctly; libraries whose kind isn't a browsable movie/series list
/// are skipped.
/// Builds the Home hero's **featured** provider from the Seerr service: trending
/// titles (movies + TV) that may live outside the user's library. Returns `[]`
/// when Seerr is unconfigured or the fetch fails, so the `.featured` hero source
/// stays inert until a server is connected — exactly the seam `HeroCurator`
/// expects.
private func makeHeroFeaturedProvider(seer: SeerService) -> FeaturedContentProviding {
    { limit in
        (try? await seer.trending(limit: limit)) ?? []
    }
}

/// Maps a `SeerRequestOutcome` to the provider-agnostic `MediaRequestActionResult`
/// the detail page consumes, translating failure reasons into TV-friendly copy
/// (with the acting user's name where it clarifies *whose* limit/permission).
/// `actingName` is the mapped Seerr user, or `nil` when requesting as admin.
private func seerRequestResult(_ outcome: SeerRequestOutcome, actingName: String?) -> MediaRequestActionResult {
    switch outcome {
    case let .success(status):
        return .success(status)
    case let .failure(reason):
        let who = actingName ?? "This account"
        switch reason {
        case .noDefaults:
            return .failure(
                title: "No Default Server",
                message: "\(actingName ?? "Your Seerr user") has no default quality profile or server set. Set one in the Seerr web app, then try again."
            )
        case .noPermission:
            return .failure(
                title: "Not Allowed",
                message: "\(who) doesn’t have permission to request this. Check the user’s permissions in Seerr."
            )
        case .quotaExceeded:
            return .failure(
                title: "Request Limit Reached",
                message: "\(who) has reached the request limit. Try again later or adjust the quota in Seerr."
            )
        case .alreadyRequested:
            return .failure(
                title: "Already Requested",
                message: "This title has already been requested."
            )
        case .invalidActingUser:
            return .failure(
                title: "Seerr User Not Found",
                message: "The linked Seerr user no longer exists. Re-link this profile in Settings ▸ This Apple TV ▸ Seerr."
            )
        case .unreachable:
            return .failure(
                title: "Can’t Reach Seerr",
                message: "Couldn’t reach the Seerr server. Check your connection and try again."
            )
        case let .unknown(message):
            return .failure(title: "Request Failed", message: message)
        }
    }
}

private func makeHeroRandomProvider(accounts: [ResolvedAccount]) -> RandomLibraryContentProviding {
    { keys, limit in
        guard !keys.isEmpty, limit > 0 else { return [] }
        var libraryIDsByAccount: [String: [String]] = [:]
        for key in keys {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let accountID = String(key[..<separator])
            let libraryID = String(key[key.index(after: separator)...])
            guard !accountID.isEmpty, !libraryID.isEmpty else { continue }
            libraryIDsByAccount[accountID, default: []].append(libraryID)
        }
        guard !libraryIDsByAccount.isEmpty else { return [] }

        let pooled = await withTaskGroup(of: [MediaItem].self) { group in
            for (accountID, libraryIDs) in libraryIDsByAccount {
                guard let provider = resolveOptionalProvider(accountID, in: accounts) else { continue }
                group.addTask {
                    let kindByLibraryID: [String: MediaItemKind]
                    do {
                        let libraries = try await provider.libraries()
                        kindByLibraryID = Dictionary(
                            libraries.map { ($0.id, $0.kind) },
                            uniquingKeysWith: { first, _ in first }
                        )
                    } catch {
                        return []
                    }
                    var collected: [MediaItem] = []
                    for libraryID in libraryIDs {
                        guard let kind = kindByLibraryID[libraryID],
                              kind == .movie || kind == .series else { continue }
                        let page = PageRequest(
                            startIndex: 0,
                            limit: max(limit, 12),
                            sort: SortDescriptor(field: .random, direction: .descending)
                        )
                        if let result = try? await provider.items(in: libraryID, kind: kind, page: page) {
                            collected.append(contentsOf: result.items)
                        }
                    }
                    return collected
                }
            }
            var all: [MediaItem] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        return Array(pooled.shuffled().prefix(max(limit, 1)))
    }
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
    let orderedAccountIDs = accounts.map(\.account.id)
    let providersByAccountID: [String: any MediaProvider] = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { primary in
        // Start from the eager index's known sources for this title — the shared
        // source of truth — so the picker is at least as complete as the watch
        // fan-out even before (or without) an on-demand probe.
        //
        // KNOWN COST (r6-playtime-fanout, documented/deferred): even when the index
        // already knows this title's sources, we still probe EVERY account below
        // for live versions/watch-state and same-server duplicates. That's a
        // fan-out of N searches per open. It's bounded (each search is deadline-
        // capped at 4s via `searchWithDeadline`) and only runs on detail-open, not
        // per-card, so it isn't hot. Using the index as the primary answer and
        // probing only the *selected* source is folded into the upcoming
        // preferred-server/bandwidth feature rather than changed here.
        var sources: [MediaSourceRef] = identitySources(primary)
        var seen = Set(sources.map(\.id))
        // Probe EVERY signed-in account, including the primary's own. The
        // primary's own item id is filtered inside the resolver so same-server
        // duplicate movie items (two Jellyfin items, one film) group into one
        // detail with a multi-entry version picker — without this only OTHER
        // servers' twins were discovered and a same-server duplicate was invisible.
        //
        // Use the caller's stable `accounts` order (NOT `Dictionary.keys`, whose
        // iteration order is unspecified and re-hashed per process): the resolver
        // reassembles hits by this input order and `bestSelection`'s final
        // primary-first tiebreak reads it, so a dictionary order would flip which
        // server backs a tied merged card between launches — a source of the
        // "server feels random" symptom.
        let everyAccount = orderedAccountIDs
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

/// Retargets a cross-server-merged card to the **locality-best** copy before it
/// is handed to the player, mirroring the detail page's best-source routing.
///
/// Home "Continue Watching" and Search play items directly (`requestPlay`)
/// instead of opening the detail page, so without this they'd launch the
/// arbitrary merge-primary source — which is why the server a card played from
/// felt random. Routing through ``CrossSourceSelector/bestSelection(from:capabilities:)``
/// makes a merged title stream from the copy on the same LAN when one exists
/// (a remote/Tailscale copy only wins when it's the sole source), and
/// ``MediaItem/retargetedForPlayback(item:sources:activeAccountID:versionID:)``
/// reconciles resume to the cross-server furthest progress so switching to the
/// local copy never rewinds. Single-source items pass through untouched.
///
/// Locality is refreshed **live** from each owning provider right here, at the
/// moment of selection, rather than trusting the value the merge/index captured
/// earlier. Locality is a runtime property — it flips the instant you leave the
/// LAN, and a Plex server advertises its own LAN address even to remote clients,
/// so a value sampled before the connection resolver had probed (and then
/// persisted in the identity index) can wrongly read `.local`. By play time every
/// provider has been exercised, so its resolver has settled on the truly-reachable
/// connection; reading `provider.connectionLocality` now and overriding each
/// source's stale locality is what makes "play from the local server" actually
/// hold instead of feeling random.
///
/// `accounts` are the currently signed-in accounts. A merged card's `sources`
/// can still list a server the user has since removed (the eager index snapshot
/// lags an account sign-out), and ``resolveProvider(_:in:)`` silently falls back
/// to `accounts[0]` for an unknown account — so selecting a dead source would
/// play the *wrong* server's copy (or fail). Pruning to live accounts before
/// selection guarantees we only ever pick a server we can actually resolve, and
/// drops the stale refs from the item handed to the player.
///
/// `identitySources` folds in cross-server twins the **live** identity index
/// knows but this card's own `sources` don't yet carry. Home "Continue Watching"
/// and Search play directly (no detail-page resolver runs), so a card that was
/// merged before a local twin finished indexing lists only the server(s) known
/// then — often the remote merge-primary. By play time the index has usually
/// warmed the local copy; unioning it here (deduped by `account:item`, the
/// card's own refs winning on collision because they carry live versions and
/// watch-state) lets the locality selection route to the LAN copy instead of
/// streaming remotely. This is the direct-play counterpart to the detail page's
/// cross-server resolver.
///
/// Episodes are a deliberate exception: the identity index only ingests movies
/// and series, so `identitySources` returns nothing for an episode and a
/// Continue-Watching episode keeps its single CW-feed source. That is by design —
/// resume progress lives on the specific server the episode was watched on, so
/// continuity (resume where you left off) beats locality for a mid-episode card.
/// Local-first for episodic content is instead achieved by navigating into the
/// series (whose detail page retargets to the most-local source once its
/// cross-server twins are discovered).
private func bestSourcePlayItem(
    _ item: MediaItem,
    accounts: [ResolvedAccount],
    identitySources: (MediaItem) -> [MediaSourceRef]
) -> MediaItem {
    let activeAccountIDs = Set(accounts.map(\.account.id))
    let liveLocality: [String: SourceLocality] = Dictionary(
        accounts.map { ($0.account.id, $0.provider.connectionLocality) },
        uniquingKeysWith: { first, _ in first }
    )
    func withLiveLocality(_ source: MediaSourceRef) -> MediaSourceRef {
        guard let locality = liveLocality[source.accountID] else { return source }
        var copy = source
        copy.locality = locality
        return copy
    }

    // Union the card's own sources with any twin the live index knows. The card's
    // refs come first and win on id collision (live versions/watch-state).
    var unioned = item.sources
    var seen = Set(unioned.map(\.id))
    for ref in identitySources(item) where seen.insert(ref.id).inserted {
        unioned.append(ref)
    }

    // Drop any un-playable Plex **Discover** source: a watchlist/Discover stub is
    // addressed by the GLOBAL catalog guid (its itemID == the `plex://…/<id>`
    // tail), which no Plex Media Server can play. Such refs can linger on an item
    // rebuilt before the merger fix, or hydrated from an older on-disk Home cache;
    // if one wins best-source selection, playback dead-ends on "Can't play this"
    // even though a real library copy exists. Filtering here is cache-proof — but
    // only when a real, playable twin remains (never strip the last source, so a
    // genuinely Discover-only title still resolves to its stub rather than nothing).
    if let guidTail = item.providerIDs["PlexGuid"]?.split(separator: "/").last.map(String.init) {
        let playable = unioned.filter { $0.itemID != guidTail }
        if !playable.isEmpty { unioned = playable }
    }

    let liveSources = (activeAccountIDs.isEmpty
        ? unioned
        : unioned.filter { activeAccountIDs.contains($0.accountID) })
        .map(withLiveLocality)

    // Honor an already-applied EXPLICIT source pick. The detail page's play path
    // retargets through `MediaItem.retargetedForPlayback` first, stamping
    // `selectedSourceAccountID` from the server picker (or its origin-aware smart
    // default) and repointing the item — but it preserves the full `sources`
    // array for further switching. Re-running best-source selection here would
    // then clobber that pick back to the locality-best copy, making the picker
    // cosmetic (a user who deliberately chose the remote/Tailscale copy would
    // still be sent to the LAN one). Only honor picks the user actually made
    // (`explicitSourceSelection`): an AUTO default (origin-following detail
    // default, or a Home/Search item that carries no explicit choice) is instead
    // re-selected below against *live* locality, so a title opened from a
    // remote/Tailscale library still plays from a same-LAN copy when one exists.
    if item.explicitSourceSelection,
       let picked = item.selectedSourceAccountID,
       liveSources.contains(where: { $0.accountID == picked }) {
        return item
    }

    // If the item's OWN (account, id) isn't itself a playable source — the
    // Discover-stub case, where its id is the global guid we filtered out above —
    // force a retarget onto the best remaining source, so we never launch the
    // un-playable id even when the real copy sits on the same account as the stub
    // (which the single-source heuristic below wouldn't otherwise catch). No-op
    // for ordinary items, whose primary (account, id) is always among liveSources.
    let primaryIsPlayable = liveSources.contains {
        $0.accountID == item.sourceAccountID && $0.itemID == item.id
    }
    if !primaryIsPlayable, !liveSources.isEmpty {
        let selection = CrossSourceSelector.bestSelection(
            from: liveSources,
            capabilities: .detected(),
            preferring: item.sourceAccountID
        )
        let target = selection?.source ?? liveSources[0]
        return MediaItem.retargetedForPlayback(
            item: item,
            sources: liveSources,
            activeAccountID: target.accountID,
            versionID: selection?.version?.id
        )
    }

    guard liveSources.count > 1,
          let selection = CrossSourceSelector.bestSelection(
              from: liveSources,
              capabilities: .detected(),
              preferring: item.selectedSourceAccountID ?? item.sourceAccountID
          )
    else {
        // One (or zero) live source. If pruning dropped servers, or the primary
        // pointed at a now-removed account, retarget onto the surviving copy so we
        // don't mis-resolve; otherwise the single-source item passes through.
        if let only = liveSources.first,
           liveSources.count < unioned.count || only.accountID != item.sourceAccountID {
            return MediaItem.retargetedForPlayback(
                item: item,
                sources: liveSources,
                activeAccountID: only.accountID,
                versionID: nil
            )
        }
        return item
    }
    return MediaItem.retargetedForPlayback(
        item: item,
        sources: liveSources,
        activeAccountID: selection.source.accountID,
        versionID: selection.version?.id
    )
}

/// Re-selects the next-best playable source after the server a card was already
/// routed to failed to start playback, so a dead/unreachable copy transparently
/// falls through to another server's copy instead of dead-ending on an error
/// screen (r8-play-failover). `tried` is the set of source account IDs already
/// attempted (the just-failed one included); the function returns `nil` once every
/// live source has been exhausted, letting the caller surface the graceful player
/// error rather than loop forever.
///
/// It mirrors ``bestSourcePlayItem``'s live-locality refresh and identity-index
/// union so failover still prefers a same-LAN copy, but differs in two ways that
/// matter only on the failure path: it does **not** honor an explicit user pick
/// (that pick is exactly what just failed, so it must be allowed to fall through),
/// and it does **not** pass a single source through untouched — a lone source that
/// failed has no alternative, so an empty untried set is a real dead end. Resume
/// is still reconciled across the full live source set (not just the untried
/// subset) so switching servers mid-title never rewinds.
private func failoverPlayItem(
    _ item: MediaItem,
    accounts: [ResolvedAccount],
    identitySources: (MediaItem) -> [MediaSourceRef],
    tried: Set<String>
) -> MediaItem? {
    let activeAccountIDs = Set(accounts.map(\.account.id))
    let liveLocality: [String: SourceLocality] = Dictionary(
        accounts.map { ($0.account.id, $0.provider.connectionLocality) },
        uniquingKeysWith: { first, _ in first }
    )
    func withLiveLocality(_ source: MediaSourceRef) -> MediaSourceRef {
        guard let locality = liveLocality[source.accountID] else { return source }
        var copy = source
        copy.locality = locality
        return copy
    }

    var unioned = item.sources
    var seen = Set(unioned.map(\.id))
    for ref in identitySources(item) where seen.insert(ref.id).inserted {
        unioned.append(ref)
    }

    let liveSources = (activeAccountIDs.isEmpty
        ? unioned
        : unioned.filter { activeAccountIDs.contains($0.accountID) })
        .map(withLiveLocality)

    // Delegate the exclusion + exhaustion decision to the (tested) selector: it
    // drops every already-tried server and returns nil when none remain.
    guard let selection = CrossSourceSelector.bestSelection(
        from: liveSources,
        capabilities: .detected(),
        preferring: nil,
        excluding: tried
    ) else {
        return nil
    }

    // Retarget against the FULL live source set so resume reconciliation still sees
    // every server's progress (furthest-wins), while the chosen account comes from
    // the untried subset the selector picked.
    return MediaItem.retargetedForPlayback(
        item: item,
        sources: liveSources,
        activeAccountID: selection.source.accountID,
        versionID: selection.version?.id
    )
}

/// Builds the player for a play request. Online (TMDb → YouTube) trailers carry a
/// YouTube video-id marker and have no backing account, so they are routed to
/// ``YouTubeTrailerProvider`` (which extracts a playable stream); every other
/// item resolves through its owning account provider as usual.
@MainActor
private func makePlayerViewModel(
    for request: PlayRequest,
    accounts: [ResolvedAccount],
    behavior: SubtitleBehavior,
    style: SubtitleStyle,
    playbackSettings: PlaybackSettings,
    spoilerSettings: SpoilerSettings,
    subtitlePolicy: SubtitlePolicy,
    audioPolicy: AudioPolicy,
    seriesTrackStore: any SeriesTrackPreferenceStoring,
    scrobbler: any TraktScrobbling,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
    onSubtitleStyleChanged: @escaping (SubtitleStyle) -> Void = { _ in },
    adoptedResolved: PlayerViewModel.PrefetchedPlayback? = nil
) -> PlayerViewModel {
    if let videoID = request.item.youTubeTrailerVideoID {
        let trailerItem = request.item
        let onlineTrailerResolver = ItemDetailViewModel.defaultOnlineTrailerResolver
        let engineFactory = HybridPlayback.engineFactory()
        let trailerViewModel = PlayerViewModel(
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
                // Adaptive (separate audio) trailers need routing through the
                // Plozzigen muxer to pair the video+audio streams; this preview
                // path uses the progressive **muxed** URL instead
                // (AVPlayer/Plozzigen play it directly). Trailers stay playable,
                // capped to the muxed resolution YouTube serves.
                allowsSeparateAudio: false
            ),
            itemID: videoID,
            behavior: behavior,
            style: style,
            subtitlePolicy: subtitlePolicy,
            audioPolicy: audioPolicy,
            playbackSettings: playbackSettings,
            spoilerSettings: spoilerSettings,
            seriesTrackStore: seriesTrackStore,
            startPosition: request.startPosition,
            scrobbler: scrobbler,
            engineFactory: engineFactory,
            autoDismissOnEnd: true
        )
        trailerViewModel.onSubtitleStyleChanged = onSubtitleStyleChanged
        return trailerViewModel
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
    // For an episode, resolve its neighbours off the main actor so a clean
    // playthrough auto-advances and controls can offer a mid-play jump. The
    // provider is captured (a value-type session); `children(of:)` lists the
    // season in broadcast order. Movies/trailers pass no resolver.
    let episodeProvider = resolveProvider(request.item.sourceAccountID, in: accounts)
    let neighborResolver: (@Sendable () async -> (previous: MediaItem?, next: MediaItem?))?
    if convergingItem.kind == .episode, let seasonID = convergingItem.seasonID {
        let originAccountID = convergingItem.sourceAccountID
        neighborResolver = {
            let siblings = (try? await episodeProvider.children(of: seasonID)) ?? []
            let tagged = originAccountID.map { id in siblings.map { $0.taggingSource(id) } } ?? siblings
            return EpisodeSequence.neighbors(of: convergingItem, in: tagged)
        }
    } else {
        neighborResolver = nil
    }
    // Resolve the series' external ids once so an episode that only carries
    // episode-level ids can still identify its show to Simkl.
    let seriesIDResolver: (@Sendable () async -> [String: String]?)?
    if convergingItem.kind == .episode, let seriesID = convergingItem.seriesID {
        seriesIDResolver = {
            (try? await episodeProvider.item(id: seriesID))?.providerIDs
        }
    } else {
        seriesIDResolver = nil
    }
    let episodeViewModel = PlayerViewModel(
        provider: episodeProvider,
        itemID: request.item.id,
        mediaSourceID: request.item.selectedVersionID,
        behavior: behavior,
        style: style,
        subtitlePolicy: subtitlePolicy,
        audioPolicy: audioPolicy,
        playbackSettings: playbackSettings,
        spoilerSettings: spoilerSettings,
        seriesTrackStore: seriesTrackStore,
        seriesAccountFallbackID: primaryAccountID,
        startPosition: request.startPosition,
        scrobbler: scrobbler,
        engineFactory: HybridPlayback.engineFactory(),
        neighborResolver: neighborResolver,
        seriesIDResolver: seriesIDResolver,
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
        ),
        adoptedResolved: adoptedResolved
    )
    episodeViewModel.onSubtitleStyleChanged = onSubtitleStyleChanged
    return episodeViewModel
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
/// it ever routes to an engine), thermal throttling, and growing lag the longer the
/// player stayed up.
///
/// Building the model in `.task`, gated by this view's identity, fires the factory
/// once per presentation instead of once per render.
///
/// **Episode advance**: when a `PlayerViewModel` sets its `pendingNextEpisode`,
/// this view swaps the VM in-place — the `Color.black` ZStack stays up so the
/// full-screen cover never dismisses and the series page never flashes through.
@MainActor
private struct PlayerPresentation: View {
    let make: (PlayRequest, PlayerViewModel.PrefetchedPlayback?) -> PlayerViewModel
    /// Re-selects the next-best source after the current target fails to start,
    /// excluding every account already attempted; `nil` means no untried source
    /// remains, so the player's own error state stays on screen (r8-play-failover).
    let makeFailover: (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?
    let showDiagnostics: Bool
    let themePalette: ThemePalette

    /// The currently-active play request; changes when auto-advancing episodes.
    @State private var activeRequest: PlayRequest
    @State private var viewModel: PlayerViewModel?
    /// Source account IDs already attempted for the active title, so failover never
    /// re-tries a server that already failed and can detect true exhaustion. Reset
    /// whenever the title changes (episode auto-advance).
    @State private var triedAccountIDs: Set<String> = []

    init(
        request: PlayRequest,
        make: @escaping (PlayRequest, PlayerViewModel.PrefetchedPlayback?) -> PlayerViewModel,
        makeFailover: @escaping (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?,
        showDiagnostics: Bool,
        themePalette: ThemePalette
    ) {
        self.make = make
        self.makeFailover = makeFailover
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
        self._activeRequest = State(initialValue: request)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: showDiagnostics,
                    themePalette: themePalette
                )
                .id(activeRequest.id)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = make(activeRequest, nil)
            }
        }
        .onChange(of: viewModel?.pendingNextEpisode?.id) { _, nextID in
            guard nextID != nil, let next = viewModel?.pendingNextEpisode else { return }
            // Adopt the next episode's prefetched resolution (if ready) BEFORE
            // stop() runs, so the incoming player skips the network resolve and
            // reuses the already-open session rather than the old player releasing
            // it. `nil` when the prefetch didn't finish → the new player resolves
            // normally (no regression).
            let prefetched = viewModel?.consumePrefetchedNext(matching: next.id)
            // Keep the panel's HDR/DV mode across a same-range hand-off so the TV
            // doesn't flap DV→SDR→DV between episodes (needs the prefetched next's
            // source facts, so it's a no-op on a prefetch miss).
            let preserveDisplay = viewModel?.shouldPreserveDisplayMode(forNext: prefetched) ?? false
            Task { @MainActor in
                // Stop + scrobble the finished episode before swapping.
                await viewModel?.stop(preserveDisplayMode: preserveDisplay)
                // Create the new VM and update the request in one synchronous
                // block so SwiftUI batches the render: the .id change forces a
                // fresh PlayerView that picks up the new VM via @State init.
                let newRequest = PlayRequest(item: next, startPosition: 0)
                // A new title starts its own failover attempt history.
                triedAccountIDs = []
                viewModel = make(newRequest, prefetched)
                activeRequest = newRequest
            }
        }
        .onChange(of: viewModel?.phase) { _, phase in
            // Playback failed to start on the routed server. Silently retarget to
            // the next-best untried source (a dead/unreachable copy falls through to
            // another server's copy) and re-present at the same resume point. When
            // no untried source remains, the player's `.failed` error stays visible.
            guard case .failed = phase else { return }
            let failedAccountID = activeRequest.item.selectedSourceAccountID
                ?? activeRequest.item.sourceAccountID
            var attempted = triedAccountIDs
            if let failedAccountID { attempted.insert(failedAccountID) }
            guard let nextItem = makeFailover(activeRequest.item, attempted) else {
                triedAccountIDs = attempted
                return
            }
            Task { @MainActor in
                await viewModel?.stop()
                let newRequest = PlayRequest(
                    item: nextItem,
                    startPosition: activeRequest.startPosition
                )
                triedAccountIDs = attempted
                viewModel = make(newRequest, nil)
                activeRequest = newRequest
            }
        }
    }
}

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
private struct HomeTab: View {
    let accounts: [ResolvedAccount]
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
                spoilerSettings: spoilerSettings,
                heroSettings: heroSettings,
                heroFeaturedProvider: makeHeroFeaturedProvider(seer: seer),
                heroRandomProvider: makeHeroRandomProvider(accounts: accounts),
                seerConnected: seer.isConfigured,
                onRequestItem: { item in
                    let outcome = await seer.request(item, actingUserID: activeSeerrUserID)
                    if case let .success(status) = outcome { return status }
                    return nil
                },
                navigationStyle: navigationStyle,
                onSelectItem: { navigate(bestSourcePlayItem($0, accounts: accounts, identitySources: identitySources)) },
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
                snapshotCache: .shared
            ),
            spoilerSettings: spoilerSettings,
            onPlay: { requestPlay($0) },
            onSelectChild: { navigate($0, libraryOrigin: libraryOrigin) },
            initialSeasonID: item.seasonID,
            isDiscoveryItem: isDiscovery,
            seerConnected: seer.isConfigured,
            onRequest: { item in
                let outcome = await seer.request(item, actingUserID: activeSeerrUserID)
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
            resumePrompt = target
        } else {
            playRequest = PlayRequest(item: target, startPosition: 0)
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

/// A fully-resolved request to present the player for an item at an explicit
/// start position (seconds). `startPosition` of `0` means "start over".
private struct PlayRequest: Identifiable, Equatable {
    let item: MediaItem
    let startPosition: TimeInterval
    var id: String { item.id }
}

private extension View {
    /// Shared player presentation host: the full-screen player + resume prompt.
    /// HomeTab and SearchTab were byte-identical here, so both route through this
    /// one modifier — auto-advance and player wiring live in a single place.
    func playerHost(
        playRequest: Binding<PlayRequest?>,
        resumePrompt: Binding<MediaItem?>,
        accounts: [ResolvedAccount],
        behavior: SubtitleBehavior,
        style: SubtitleStyle,
        playbackSettings: PlaybackSettings,
        spoilerSettings: SpoilerSettings,
        subtitlePolicy: SubtitlePolicy,
        audioPolicy: AudioPolicy,
        seriesTrackStore: any SeriesTrackPreferenceStoring,
        scrobbler: any TraktScrobbling,
        watchBridge: WatchOutboxBridge,
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        showDiagnostics: Bool,
        themePalette: ThemePalette,
        onSubtitleStyleChanged: @escaping (SubtitleStyle) -> Void
    ) -> some View {
        fullScreenCover(item: playRequest) { request in
            PlayerPresentation(
                request: request,
                make: { request, adopted in
                    makePlayerViewModel(
                        for: request,
                        accounts: accounts,
                        behavior: behavior,
                        style: style,
                        playbackSettings: playbackSettings,
                        spoilerSettings: spoilerSettings,
                        subtitlePolicy: subtitlePolicy,
                        audioPolicy: audioPolicy,
                        seriesTrackStore: seriesTrackStore,
                        scrobbler: scrobbler,
                        watchBridge: watchBridge,
                        identitySources: identitySources,
                        onSubtitleStyleChanged: onSubtitleStyleChanged,
                        adoptedResolved: adopted
                    )
                },
                makeFailover: { failedItem, tried in
                    failoverPlayItem(
                        failedItem,
                        accounts: accounts,
                        identitySources: identitySources,
                        tried: tried
                    )
                },
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: resumePrompt) { item, startPosition in
            playRequest.wrappedValue = PlayRequest(item: item, startPosition: startPosition)
        }
    }
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
                    seerSearch: { [seer] query in (try? await seer.search(query)) ?? [] }
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
                        snapshotCache: .shared
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialSeasonID: item.seasonID,
                    isDiscoveryItem: isDiscovery,
                    seerConnected: seer.isConfigured,
                    onRequest: { item in
                        let outcome = await seer.request(item, actingUserID: activeSeerrUserID)
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
        let target = bestSourcePlayItem(item, accounts: accounts, identitySources: identitySources)
        if let resume = target.resumePosition, resume > 1 {
            resumePrompt = target
        } else {
            playRequest = PlayRequest(item: target, startPosition: 0)
        }
    }
}

#endif
