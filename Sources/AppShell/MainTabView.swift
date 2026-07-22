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
    /// The detail-snapshot cache scoped to the active content identity (profile +
    /// accounts + Plex Home-user generation), injected from `RootView` so every
    /// detail destination shares one identity-isolated instance instead of the
    /// process-global `.shared` cache (which leaked snapshots across identities).
    let detailSnapshotCache: DetailSnapshotCache
    /// Resolves the active accounts at action time for retained Settings
    /// destinations whose render-time `accounts` snapshot may be stale.
    let currentAccounts: @MainActor () -> [ResolvedAccount]
    let networkFileResolver: any MediaTransportNetworkFileResolving
    let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    /// Offline-download seam: when a completed download exists for the item,
    /// playback is rewritten to the local file. `nil` = offline is a no-op.
    let offlinePlaybackResolver: (any OfflinePlaybackResolving)?
    /// Subtitle behaviour (mode / language / auto-download) and appearance
    /// (`SubtitleStyle`) split out of the retired `CaptionSettings`. Behaviour
    /// feeds the policy resolver; style seeds the player + live overlay.
    let profileSettings: ProfileSettingsModel
    let syncServices: SyncServices
    private var subtitleBehaviorModel: SubtitleBehaviorModel { profileSettings.subtitleBehaviorModel }
    private var subtitleStyleModel: SubtitleStyleModel { profileSettings.subtitleStyleModel }
    private var spoilerModel: SpoilerSettingsModel { profileSettings.spoilerModel }
    private var playbackModel: PlaybackSettingsModel { profileSettings.playbackModel }
    /// Per-profile per-content-type subtitle policy overrides, threaded into the
    /// player (resolved against the caption base) and into Settings for editing.
    private var subtitlePolicyModel: SubtitlePolicyModel { profileSettings.subtitlePolicyModel }
    /// Per-profile per-content-type audio-language overrides, threaded into the
    /// player (resolved against the playback base) and into Settings for editing.
    private var audioPolicyModel: AudioPolicyModel { profileSettings.audioPolicyModel }
    private var themeModel: ThemeSettingsModel { profileSettings.themeModel }
    private var themeMusicModel: ThemeMusicSettingsModel { profileSettings.themeMusicModel }
    private var heroBackgroundModel: HeroBackgroundSettingsModel { profileSettings.heroBackgroundModel }
    /// Per-profile remembered per-series audio/subtitle selections, threaded into
    /// the player so a manual track switch sticks across that show's episodes.
    let seriesTrackStore: any SeriesTrackPreferenceStoring
    private var diagnosticsModel: DiagnosticsSettingsModel { profileSettings.diagnosticsModel }
    /// App-wide, opt-in crash-reporting consent (off by default). Threaded into
    /// Settings ▸ Help & Diagnostics so the household can turn it on/off.
    let crashReportingModel: CrashReportingSettingsModel
    /// Whether this build has a crash-reporting endpoint baked in; drives whether
    /// the opt-in toggle is enabled or shown disabled with a note.
    let crashReportingConfigured: Bool
    private var musicPlayerModel: MusicPlayerSettingsModel { profileSettings.musicPlayerModel }
    /// Per-profile UI density, injected into the environment below so the
    /// Settings ▸ Appearance picker can edit it.
    private var uiDensityModel: UIDensitySettingsModel { profileSettings.uiDensityModel }
    /// Per-profile media card style, edited in Settings ▸ Appearance ▸ Display.
    /// Injected into the environment for the Settings editor; card rendering reads
    /// `\.plozzCardStyle` (installed at the app root in RootView).
    private var cardStyleModel: CardStyleSettingsModel { profileSettings.cardStyleModel }
    /// Per-profile watch-status indicator (a "watched" check badge vs an
    /// "unwatched" corner flag), edited in Settings ▸ Appearance ▸ Display.
    /// Injected into the environment for the Settings editor; card rendering reads
    /// `\.plozzWatchStatusIndicator` (installed at the app root in RootView).
    private var watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel { profileSettings.watchStatusIndicatorModel }
    /// Per-profile navigation chrome (top bar vs. sidebar), edited in Settings ▸
    /// Appearance ▸ Display. This view reads its `style` to pick the `TabViewStyle`;
    /// the Settings editor binds the model, and chrome-sensitive views elsewhere
    /// read `\.plozzNavigationStyle` (installed at the app root in RootView).
    private var navigationStyleModel: NavigationStyleSettingsModel { profileSettings.navigationStyleModel }
    /// Per-profile transparency (liquid glass) preference, edited in Settings ▸
    /// Appearance ▸ Display. Injected into the environment for the Settings editor;
    /// the resolved value drives `\.plozzReduceTransparency` (installed in RootView).
    private var transparencyModel: TransparencyPreferenceModel { profileSettings.transparencyModel }
    /// Per-profile Home hero (featured carousel) settings, edited in
    /// Settings ▸ Home display. Threaded into `HomeTab` to drive the carousel and
    /// into Settings for editing.
    private var heroSettingsModel: HeroSettingsModel { profileSettings.heroSettingsModel }
    /// App-wide media-share scan/enrich status, injected into the environment so
    /// Home shows an "Updating library…" banner and Settings shows last-scanned.
    let shareScanStatusModel: ShareScanStatusModel
    /// Per-profile Night Shift settings, edited in Settings ▸ Night Shift. Its
    /// overlay is installed at the app root (RootView); here it's only threaded
    /// into Settings for editing.
    private var nightShiftModel: NightShiftSettingsModel { profileSettings.nightShiftModel }
    /// App-scoped audio engine, owned by `AppState` so it survives the per-profile
    /// subtree rebuild (this view is re-created with a new `.id` on profile switch).
    let audioController: AudioPlaybackController
    private var homeVisibility: HomeLibraryVisibilityModel { profileSettings.homeLibraryVisibilityModel }
    /// Per-profile store for the last-rendered Home row structure, used to seed
    /// the loading skeleton so it matches the user's real Home before content
    /// arrives. Constructed with the active profile's namespace by `RootView`.
    let homeLayoutStore: HomeLayoutStoring
    /// Per-profile store for the last successful Home content snapshot, so the hero
    /// + Continue Watching (and the rest of Home) paint instantly on launch and
    /// then silently refresh. Constructed with the active profile's namespace by
    /// `RootView` (same lifecycle as `homeLayoutStore`).
    let homeContentStore: HomeContentStoring
    private var ratingsProvider: any ExternalRatingsProviding { syncServices.ratingsProvider }
    private var trakt: TraktService { syncServices.trakt }
    private var simkl: SimklService { syncServices.simkl }
    private var seer: SeerService { syncServices.seer }
    private var anilist: AniListService { syncServices.anilist }
    private var mal: MALService { syncServices.mal }
    private var lastfm: LastFmService { syncServices.lastfm }
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
    /// Presents the tvOS "set up another device" (sender) flow. Optional so the
    /// feature can be omitted; hosted by RootView where AppState is available.
    var onSetUpAnotherDevice: (() -> Void)?

    /// Cross-device sync opt-in state + setter, forwarded to Settings.
    var syncEnabled: Bool = false
    var onSetSyncEnabled: ((Bool) -> Void)?
    /// Live sync status summary + manual sync action for the iCloud Sync page.
    var syncStatusSummary: String?
    var onSyncNow: (() -> Void)?
    var onResetSync: (() -> Void)?
    /// Pending (needs-sign-in) synced servers + their actions.
    var pendingSyncedServers: [SyncedAccountDescriptor] = []
    var onIgnorePendingServer: (String) -> Void = { _ in }
    var onSetUpFromAnotherDevice: (() -> Void)?

    @State private var discovery = LibraryDiscoveryModel()
    /// Owns the Settings library-discovery result as an `@Observable` reference so
    /// that a reload (which fires on Settings appearance, DURING the tab focus-flip)
    /// only re-renders the library detail pages that read it — never the Settings
    /// ROOT list. Threading the raw `LoadState` value through `SettingsView`
    /// instead rebuilt the root rows mid-flip → `setToViewXFlippedScreenShot:` UAF.
    @State private var librariesStore = DiscoveredLibrariesStore()
    @State private var libraryReloadRevision = 0
    @State private var musicAvailability = MusicAvailabilityModel()
    @State private var themeMusicController = ThemeMusicController()
    /// One app-level trailer player shared by the Home and detail heroes so
    /// hero→detail navigation can keep the same trailer rolling.
    @State private var heroTrailerController = HeroTrailerController()
    /// Retains loaded Hero content across tvOS tab subtree recreation.
    @State private var homeHeroRuntime = HomeHeroRuntimeState()
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

    private var accountScopeKey: String {
        HomeRuntimeScope.accountScopeKey(accounts.map(\.account))
    }

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
            HomeTab(
                accounts: accounts,
                detailSnapshotCache: detailSnapshotCache,
                authenticatedHTTPResolver: authenticatedHTTPResolver,
                seer: seer,
                activeSeerrUserID: activeProfile.seerrUserID,
                activeSeerrUserName: activeProfile.seerrUserName,
                confirmAdminRequest: profiles.count > 1,
                homeVisibility: homeVisibility,
                homeLayoutStore: homeLayoutStore,
                homeContentStore: homeContentStore,
                heroSettings: heroSettingsModel,
                heroBackground: heroBackgroundModel,
                heroTrailerController: heroTrailerController,
                heroRuntime: homeHeroRuntime,
                navigationStyle: navigationStyle,
                behavior: subtitleBehaviorModel.settings,
                style: subtitleStyleModel.style,
                playbackSettings: playbackModel.settings,
                subtitlePolicy: subtitlePolicyModel.resolvedPolicy(behavior: subtitleBehaviorModel.settings),
                audioPolicy: audioPolicyModel.resolvedPolicy(settings: playbackModel.settings),
                seriesTrackStore: seriesTrackStore,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                // Home performance HUD, gated on the Help & Diagnostics toggle
                // (Diagnostics ▸ Home Performance Overlay). Off by default and opt-in
                // per profile. Remote env-gated PLZPERF capture also remains available.
                homePerfOverlayEnabled: diagnosticsModel.settings.homePerformanceOverlayEnabled,
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
            .id(accountScopeKey)
            }

            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search) {
            SearchTab(
                accounts: accounts,
                detailSnapshotCache: detailSnapshotCache,
                authenticatedHTTPResolver: authenticatedHTTPResolver,
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
            .id(accountScopeKey)
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
                    authenticatedHTTPResolver: authenticatedHTTPResolver,
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
                themeMusic: themeMusicModel,
                heroBackground: heroBackgroundModel,
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
                    await reloadLibrariesFromCurrentScope()
                },
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
                onSetAccountIncluded: { accountID, included in
                    onSetAccountIncluded(accountID, included)
                    scheduleLibraryReloadFromCurrentScope(changedAccountID: accountID)
                },
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
                onSetSeerrUser: onSetSeerrUser,
                onSetUpAnotherDevice: onSetUpAnotherDevice,
                syncEnabled: syncEnabled,
                onSetSyncEnabled: onSetSyncEnabled,
                syncStatusSummary: syncStatusSummary,
                onSyncNow: onSyncNow,
                onResetSync: onResetSync,
                pendingSyncedServers: pendingSyncedServers,
                onIgnorePendingServer: onIgnorePendingServer,
                onSetUpFromAnotherDevice: onSetUpFromAnotherDevice
            )
            }
        }
        .plozzTabStyle(navigationStyle)
        .onChange(of: selectedTabRaw, initial: true) { _, tab in
            BrowseDiagnostics.event("screen tab=\(tab)")
        }
        .onChange(of: accountScopeKey) {
            homeHeroRuntime.resetForSourceScopeChange()
            onWarmIdentityIndex()
        }
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
            networkFileResolver: networkFileResolver,
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            offlinePlaybackResolver: offlinePlaybackResolver,
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
        .environment(\.themeMusicController, themeMusicController)
        .environment(\.themeMusicSettings, themeMusicModel.settings)
        .environment(heroTrailerController)
        .environment(heroBackgroundModel)
        .environment(
            \.themeMusicAuthenticatedHTTPResolver,
            authenticatedHTTPResolver
        )
        .onChange(of: audioController.hasActivePlayback, initial: true) { _, active in
            themeMusicController.setBlocked(active)
        }
        .onChange(of: playRequest != nil) { _, videoStarting in
            if videoStarting {
                themeMusicController.stop()
            }
            // Full-screen playback suspends the ambient hero in place; dismissing
            // the player resumes the same trailer/timeline instead of restarting.
            heroTrailerController.setPaused(videoStarting)
        }
        .onChange(of: heroBackgroundModel.settings, initial: true) { _, settings in
            // Keep the legacy theme-music settings/controller in sync with the
            // new structural XOR setting. Volume remains owned by its existing
            // model; only enabled state moves here.
            themeMusicModel.settings.isEnabled = settings.themeMusicEnabled
            if settings.mode != .trailer {
                heroTrailerController.stop()
            } else {
                heroTrailerController.setMuted(settings.trailerMuted)
            }
            themeMusicController.setBlocked(
                settings.mode == .trailer && heroTrailerController.isPlaying
            )
        }
        .onChange(of: heroTrailerController.isPlaying) { _, playing in
            themeMusicController.setBlocked(
                heroBackgroundModel.settings.mode == .trailer && playing
            )
        }
        .onChange(of: selectedTabRaw) {
            themeMusicController.stop()
            heroTrailerController.stop()
        }
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

    @MainActor
    private func reloadLibrariesFromCurrentScope() async {
        libraryReloadRevision += 1
        let revision = libraryReloadRevision
        let scopedAccounts = currentAccounts()
        librariesStore.beginRefresh(
            accountIDs: Set(scopedAccounts.map(\.account.id))
        )
        await Task.yield()
        let libraries = await discovery.libraries(from: scopedAccounts)
        guard revision == libraryReloadRevision else { return }
        librariesStore.finishRefresh(with: libraries)
    }

    @MainActor
    private func scheduleLibraryReloadFromCurrentScope(changedAccountID: String) {
        libraryReloadRevision += 1
        let revision = libraryReloadRevision
        librariesStore.beginRefresh(accountIDs: [changedAccountID])
        Task { @MainActor in
            await Task.yield()
            let libraries = await discovery.libraries(from: currentAccounts())
            guard revision == libraryReloadRevision else { return }
            librariesStore.finishRefresh(with: libraries)
        }
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
#endif
