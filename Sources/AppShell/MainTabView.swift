#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
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
/// Bundles the DEBUG-only Settings actions into one value so the (very large)
/// `MainTabView` initializer takes a single argument for them rather than several
/// — keeping the call site within the Swift type-checker's time budget.
struct DebugSettingsActions {
    let resetToFirstRun: () -> Void
    /// `nil` where the "Erase Everything From iCloud" test action is unavailable.
    let eraseICloud: (() -> Void)?

    init(resetToFirstRun: @escaping () -> Void, eraseICloud: (() -> Void)? = nil) {
        self.resetToFirstRun = resetToFirstRun
        self.eraseICloud = eraseICloud
    }
}

struct MainTabView: View {
    /// Stable identifiers for the root tabs, used to persist and restore the
    /// selected tab across MainTabView being rebuilt (see `selectedTab`).
    /// The pending person route, visible ONLY to the tab that is showing.
    ///
    /// Both tabs observe the same value, so without this gate both would push
    /// the same page and the hidden one would keep it on its stack.
    /// Whether `tab` is the one on screen. A plain `Bool` rather than a
    /// tab-gated `Binding`, and that difference is the point — see below.
    private func isActiveTab(_ tab: MainTab) -> Bool {
        // Under the rail there is exactly ONE destination on screen, so "is this
        // the visible stack" is a question about the rail's selection, not about a
        // TabView that isn't there. Getting this wrong would let a hidden stack
        // consume the player's pending person/title hand-off.
        guard navigationStyle != .rail else {
            switch tab {
            case .home:
                switch resolvedRailSelection {
                case .home, .library, .allLibraries: return true
                case .search, .music, .settings: return false
                }
            case .search: return resolvedRailSelection == .search
            case .music: return resolvedRailSelection == .music
            case .settings: return resolvedRailSelection == .settings
            }
        }
        return selectedTabRaw == tab.rawValue
    }

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
    /// Per-profile store for the last successful Home content snapshot. Stable rows
    /// paint immediately; volatile Continue Watching and mixed heroes wait for fresh
    /// aggregation. Constructed with the active profile's namespace by
    /// `RootView` (same lifecycle as `homeLayoutStore`).
    let homeContentStore: HomeContentStoring
    /// Per-profile paint hint for the navigation rail's library slots, so the chrome
    /// shows the viewer's real libraries immediately instead of filling in once
    /// discovery lands. Same lifecycle as `homeLayoutStore`.
    let navigationLibrariesSnapshotStore: NavigationLibrariesSnapshotStoring
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
    /// Bumps when the effective Plex identity changes. Part of `homeScopeKey`,
    /// because switching "watching as" changes whose rows these are without
    /// changing the profile or the account list.
    let plexIdentityGeneration: Int
    let askProfileOnStartup: Bool
    /// Session-scoped handles for the Home tab, assembled by `RootView`. Stored
    /// rather than computed here on purpose: this view's body is a `TabView`
    /// with four large tabs, and it sits close enough to the Swift
    /// type-checker's budget that one extra computed value in it fails the
    /// build outright.
    let homeRuntime: HomeTabRuntime
    let isAccountIncludedInActiveProfile: (String) -> Bool
    let onSetAccountIncluded: (String, Bool) -> Void
    let onSetAskProfileOnStartup: (Bool) -> Void
    let onSaveProfile: (ProfileDraft) -> Void
    var onCreateProfile: (ProfileDraft) -> Void = { _ in }
    /// Live cosmetics-only persistence for editing an existing profile (see
    /// `AppState.updateProfileCosmetics`), so the editor can auto-save.
    let onUpdateProfileCosmetics: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    let onAddAccount: () -> Void
    var onAddUser: (MediaServer) -> Void = { _ in }
    let onRemoveAccount: (Account) -> Void
    let onRemoveAccountEverywhere: (Account) -> Void
    var offersRemoveEverywhere: Bool = false
    let onRescanShare: (String) -> Void
    /// Lets Home poke the media shares on a timer, so content that arrives while
    /// the viewer sits there is noticed. Injected like `onRescanShare` rather than
    /// reached through an environment object.
    let onPollShares: () -> Void
    let onSignOutAll: () -> Void
    let onSwitchProfile: () -> Void
    let debugActions: DebugSettingsActions
    let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void
    /// Sets or clears a profile's PIN gate. Defaulted so previews/tests can omit it.
    var onSetProfileLock: (String, ProfileLock?) -> Void = { _, _ in }
    var validatePlexPIN: (String, String) async -> PlexPINValidationResult = {
        _, _ in .unavailable
    }
    /// Marks a profile as restricted (or lifts it).
    var onSetKidsProfile: (String, Bool) -> Void = { _, _ in }
    /// Whether a profile's PIN has been proved this run.
    var isProfileUnlocked: (String) -> Bool = { _ in true }
    /// Records that a profile's PIN was just proved.
    var onProfileUnlocked: (String) -> Void = { _ in }
    /// Maps a household profile to a Seerr user (or clears it) — forwarded to the
    /// Settings "requests are made as" list.
    var onSetSeerrUser: (String, SeerUser?) -> Void = { _, _ in }
    /// Step 6 metadata settings surface (providers/attribution/diagnostics/cache),
    /// forwarded to `SettingsView`. Defaulted so previews/tests can omit it.
    var metadataSettings: MetadataSettingsDependencies? = nil
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
    var syncStatusSummary: SyncStatusProvider?
    var onSyncNow: (() -> Void)?
    var syncRepair: SyncRepairActions?
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
    /// The rail's selected destination, persisted separately from the TabView's so
    /// switching chrome never lands on a destination the other style can't show.
    @SceneStorage("navigationRail.selection")
    private var railSelectionRaw = NavigationRailDestination.home.storageValue
    /// Whether a detail page is on top of the visible destination, so the rail can
    /// step aside. Owned here and injected, so the stacks that know their depth can
    /// report it without any of them knowing about the chrome.
    @State private var navigationChrome = NavigationChromeModel()
    /// The libraries the rail offers. Seeded from the per-profile snapshot on
    /// appearance (instant chrome) and then refreshed from live discovery.
    @State private var railLibraries: [AggregatedLibrary] = []
    /// A person page the in-player Cast card asked for, waiting to be pushed.
    ///
    /// Consumed by whichever tab is on screen — see `personRoute(for:)`. Held
    /// here because the player that raises it is presented at this level.
    @State private var pendingPersonRoute: PersonRoute?
    /// A title the in-player Cast card asked for, waiting to be pushed once the
    /// player has closed. Same hand-off as `pendingPersonRoute`.
    @State private var pendingTitleRoute: MediaItem?

    private var selectedTab: Binding<MainTab> {
        Binding(
            get: { MainTab(rawValue: selectedTabRaw) ?? .home },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    private var navigationStyle: NavigationStyle {
        navigationStyleModel.style
    }

    // MARK: - Custom navigation rail

    private var railSelection: Binding<NavigationRailDestination> {
        Binding(
            get: { NavigationRailDestination(storageValue: railSelectionRaw) ?? .home },
            set: { railSelectionRaw = $0.storageValue }
        )
    }

    /// The libraries the profile can actually browse right now: discovered, not
    /// switched off, not music (music has its own destination).
    private var browsableRailLibraries: [AggregatedLibrary] {
        NavigationRailPlan.browsableLibraries(
            railLibraries.filter { homeVisibility.isEnabled($0.key) }
        )
    }

    /// The rail's library slots, in the profile's own arrangement.
    private var railEntries: [NavigationRailLibraryEntry] {
        NavigationRailPlan.entries(
            visibleLibraries: railLibraries.filter { homeVisibility.isEnabled($0.key) },
            layout: navigationStyleModel.libraryLayout
        )
    }

    /// The selection after pruning: a library that has been hidden, removed, or
    /// signed out of falls back to Home rather than leaving a blank screen.
    private var resolvedRailSelection: NavigationRailDestination {
        NavigationRailPlan.resolvedSelection(
            railSelection.wrappedValue,
            entries: railEntries,
            hasMusic: musicAvailability.hasMusic
        )
    }

    /// Re-runs library discovery for the rail when the signed-in accounts or the
    /// per-profile library switches change.
    private var railLibrariesKey: String {
        let ids = accounts.map(\.account.id).sorted()
        let disabled = homeVisibility.visibility.disabledKeys.sorted()
        return (ids + ["|"] + disabled).joined(separator: ",")
    }

    private var resolvedPalette: ThemePalette {
        // `systemColorScheme` here is the scheme RootView pushed down via
        // `.environment(\.colorScheme,)` — for `.system` that equals the real
        // device scheme, so Settings' theme switching follows the device.
        ThemePalette.palette(for: themeModel.theme, systemColorScheme: systemColorScheme)
    }

    /// The identity of both tab subtrees. Includes the active profile, so
    /// switching profiles rebuilds Home/Search even when the two profiles share
    /// the same servers — otherwise the cached view model keeps serving the
    /// previous profile's rows.
    private var homeScopeKey: String {
        HomeRuntimeScope.homeScopeKey(
            profileID: activeProfile.id,
            accounts: accounts.map(\.account),
            plexIdentityGeneration: plexIdentityGeneration
        )
    }


    /// Extracted from `body` deliberately. `SettingsView` takes 65 arguments,
    /// and leaving that call inside the `TabView` expression pushed the whole
    /// body past the Swift type-checker's budget — the build failed outright
    /// with "unable to type-check this expression in reasonable time" as soon
    /// as anything else in the body grew. Naming it gives the checker a fixed
    /// point and keeps the tab list readable.
    private var settingsTabContent: some View {
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
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                repoURL: AppInfo.repoURLString,
                isAccountIncludedInActiveProfile: isAccountIncludedInActiveProfile,
                onSetAccountIncluded: { accountID, included in
                    onSetAccountIncluded(accountID, included)
                    scheduleLibraryReloadFromCurrentScope(changedAccountID: accountID)
                },
                onSetAskProfileOnStartup: onSetAskProfileOnStartup,
                onSwitchProfile: onSwitchProfile,
                onSaveProfile: onSaveProfile,
                onCreateProfile: onCreateProfile,
                onUpdateProfileCosmetics: onUpdateProfileCosmetics,
                onDeleteProfile: onDeleteProfile,
                onAddAccount: onAddAccount,
                onAddUser: onAddUser,
                onRemoveAccount: onRemoveAccount,
                onRemoveAccountEverywhere: onRemoveAccountEverywhere,
                offersRemoveEverywhere: offersRemoveEverywhere,
                onRescanShare: onRescanShare,
                onSignOutAll: onSignOutAll,
                onResetToFirstRun: debugActions.resetToFirstRun,
                onEraseICloud: debugActions.eraseICloud,
                plexHomeUsersFetcher: plexHomeUsersFetcher,
                onSelectPlexHomeUser: onSelectPlexHomeUser,
                onSetProfileLock: onSetProfileLock,
                validatePlexPIN: validatePlexPIN,
                onSetKidsProfile: onSetKidsProfile,
                isProfileUnlocked: isProfileUnlocked,
                onProfileUnlocked: onProfileUnlocked,
                onSetSeerrUser: onSetSeerrUser,
                onSetUpAnotherDevice: onSetUpAnotherDevice,
                syncEnabled: syncEnabled,
                onSetSyncEnabled: onSetSyncEnabled,
                syncStatusSummary: syncStatusSummary,
                onSyncNow: onSyncNow,
                syncRepair: syncRepair,
                pendingSyncedServers: pendingSyncedServers,
                onIgnorePendingServer: onIgnorePendingServer,
                onSetUpFromAnotherDevice: onSetUpFromAnotherDevice,
                metadataSettings: metadataSettings
            )
            .background { SettingsPageBackground() }
    }


    /// Extracted from `body`: the `HomeTab` initializer takes ~40 arguments and,
    /// inside the `TabView` expression, it is a large part of why this body sat
    /// on the Swift type-checker's budget.
    private func homeTabContent(root: HomeTabRoot = .home, id: String? = nil) -> some View {
            // TEMPORARY discriminator. HomeTab's body runs ~46/s during the hang
            // while MainTabView's body does not run at all, which leaves two very
            // different explanations: either this closure is being re-evaluated
            // (so HomeTab's VALUE is rebuilt, and the cause is an observable read
            // in MainTabView's scope), or HomeTab is invalidating itself from its
            // own dependency. `_printChanges` cannot tell them apart here, because
            // the `Binding(get:set:)` values below are non-comparable and get
            // blamed either way. This tick answers it directly.
            let _ = PlozzBodyRate.tick("homeTabContent")
            return HomeTab(
                root: root,
                accounts: accounts,
                configuredServerCount: displayAccounts.count,
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
                onPollShares: onPollShares,
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
                pendingWatchMutations: pendingWatchMutations,
                appliedWatchRecency: appliedWatchRecency,
                onSubtitleStyleChanged: { subtitleStyleModel.style = $0 },
                playRequest: $playRequest,
                resumePrompt: $resumePrompt,
                pendingPersonRoute: $pendingPersonRoute,
                pendingTitleRoute: $pendingTitleRoute,
                isActiveTab: isActiveTab(.home),
                runtime: homeRuntime
            )
            // A rail library root gets its own identity, so switching libraries
            // rebuilds the stack instead of re-using the previous library's grid.
            .id(id ?? homeScopeKey)
    }

    /// The Music destination.
    ///
    /// The availability model is handed over by REFERENCE and read inside the Music
    /// tab, not unpacked here. Reading `detectedAccounts` / `visibleLibraryIDs` in
    /// this body made the whole tab tree a subscriber of them, so the first cache
    /// seed after launch re-ran the body and took the Home tab's `@State` — and its
    /// entire in-flight four-account load — down with it.
    private var musicTabContent: some View {
        MusicAvailabilityScope(
            availability: musicAvailability,
            controller: audioController,
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            appTheme: themeModel.theme,
            musicPlayer: musicPlayerModel,
            showNowPlaying: $showNowPlaying
        )
    }

    /// Extracted for the same reason as ``homeTabContent`` — see there.
    private var searchTabContent: some View {
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
                resumePrompt: $resumePrompt,
                pendingPersonRoute: $pendingPersonRoute,
                pendingTitleRoute: $pendingTitleRoute,
                isActiveTab: isActiveTab(.search)
            )
            .id(homeScopeKey)
    }

    /// The whole signed-in shell, in whichever chrome the profile chose. Every
    /// modifier the shell needs — the player hosts, the environment injections, the
    /// music probe — is applied to this in `body`, so the two chromes can never
    /// drift in what they provide.
    @ViewBuilder
    private var shellContent: some View {
        if navigationStyle == .rail {
            railShell
        } else {
            tabShell
        }
    }

    /// A stable key for "which destination is on screen", used by the diagnostics
    /// event and the ambient-audio stop. Spans both chromes so neither needs its own
    /// copy of those rules.
    private var activeDestinationKey: String {
        navigationStyle == .rail ? resolvedRailSelection.storageValue : selectedTabRaw
    }

    /// The two native tvOS `TabView` presentations.
    private var tabShell: some View {
        TabView(selection: selectedTab) {
            Tab("Home", systemImage: "house.fill", value: MainTab.home) {
                homeTabContent()
            }

            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search) {
                searchTabContent
            }

            // Conditional Music tab: present only when at least one signed-in
            // account exposes a music library. Video-only users see no tab and no
            // mini-player — the app is byte-for-byte unchanged for them.
            if musicAvailability.hasMusic {
                Tab("Music", systemImage: "music.note", value: MainTab.music) {
                    musicTabContent
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                settingsTabContent
            }
        }
        .plozzTabStyle(navigationStyle)
    }

    /// Plozz's own chrome: the collapsible library rail plus the selected
    /// destination.
    private var railShell: some View {
        NavigationRailShell(
            profile: activeProfile,
            entries: railEntries,
            showsMusic: musicAvailability.hasMusic,
            selection: railSelection,
            onOpenProfileSwitcher: onSwitchProfile,
            chrome: navigationChrome,
            content: railDestination
        )
        .environment(navigationChrome)
        .task(id: railLibrariesKey) {
            // Paint the rail's real libraries on the first frame from the persisted
            // snapshot — no network — then refresh below. Without this the chrome
            // would appear with Home/Search/Settings and pop libraries in a beat
            // later on every launch.
            let remembered = navigationLibrariesSnapshotStore.load()
            if railLibraries.isEmpty, !remembered.isEmpty {
                railLibraries = remembered
            }
        }
        .task(id: railLibrariesKey, priority: .utility) {
            // Everything network-bound stays out of the launch window, exactly like
            // the music probe: the snapshot already drew the rail, so this only
            // reconciles it with what the servers actually have.
            let discovered = await discovery.libraryDiscovery(from: currentAccounts())
            guard !Task.isCancelled else { return }
            // An account that failed to answer contributes nothing this pass; keep
            // the remembered set rather than blanking the chrome on a blip.
            guard !discovered.libraries.isEmpty || discovered.unreachableAccountIDs.isEmpty else { return }
            railLibraries = discovered.libraries
            navigationLibrariesSnapshotStore.save(discovered.libraries)
        }
    }

    /// The destination the rail has selected.
    @ViewBuilder
    private var railDestination: some View {
        switch resolvedRailSelection {
        case .home:
            homeTabContent()
        case .search:
            searchTabContent
        case .music:
            musicTabContent
        case .settings:
            settingsTabContent
        case .allLibraries:
            homeTabContent(
                root: .allLibraries(browsableRailLibraries),
                id: "\(homeScopeKey)|allLibraries"
            )
        case let .library(key):
            if let entry = railEntries.first(where: { $0.key == key }), let library = entry.library {
                homeTabContent(root: .library(library.library), id: "\(homeScopeKey)|\(key)")
            } else {
                homeTabContent()
            }
        }
    }

    var body: some View {
        // TEMPORARY. MainTabView was the one view in the detail-page loop with no
        // probe, and the loop is driven through the bindings IT creates: the
        // capture showed HomeTab reporting only `_pendingPersonRoute,
        // _pendingTitleRoute changed`, 3,559 times, with its own state and
        // `__path` untouched. Those two bindings are built inline here, so a
        // re-run of this body hands HomeTab fresh ones every pass. Without this
        // probe the cycle is invisible at exactly the point it turns over.
        let _ = plozzPrintChanges { Self._printChanges() }
        let _ = PlozzBodyRate.tick("MainTabView")
        return shellContent
        .onChange(of: activeDestinationKey, initial: true) { _, destination in
            BrowseDiagnostics.event("screen tab=\(destination)")
            // Keeps person tracing alive across relaunches once it has been
            // asked for, so restoring the live stream never costs the repro.
            PersonDiagnostics.armLatchIfTracing()
        }
        .onChange(of: homeScopeKey) { previous, current in
            // TEMPORARY. `homeScopeKey` is the `.id()` of BOTH tab subtrees, so
            // every change destroys and rebuilds the whole Home/Search tree —
            // including any detail page pushed on top of it. That is the only
            // thing on this path that explains `DetailStackDepth` cycling
            // appeared/dismissed during a hang, and the suspicion is that the key
            // is still settling while accounts load (opening a title before the
            // load finishes is the reported trigger). Logged as a transition, so
            // it costs nothing unless it actually moves.
            PlozzLog.boot(
                "ScopeKey CHANGED accounts=\(accounts.count) "
                + "fromLen=\(previous.count) toLen=\(current.count) to=\(current.prefix(120))"
            )
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
            onSubtitleStyleChanged: { subtitleStyleModel.style = $0 },
            // Close the player, then hand the person to whichever tab is
            // showing. The player is hosted here on the root TabView while the
            // navigation stacks live inside the tabs, so this is the only place
            // that can see both.
            onOpenPerson: { person, accountID in
                playRequest = nil
                pendingPersonRoute = PersonRoute(person: person, sourceAccountID: accountID)
            },
            onOpenTitle: { item in
                playRequest = nil
                pendingTitleRoute = item
            }
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
            // Theme music is a DETAIL-page concern; keep the legacy theme-music
            // controller's enabled state mirrored from the detail mode.
            themeMusicModel.settings.isEnabled = settings.themeMusicEnabled
            // Stop the shared trailer player only when NEITHER surface wants a
            // trailer; otherwise leave it to the active hero view. Mute is a live
            // session state on the controller, so it isn't touched here.
            if !settings.homeTrailerEnabled && !settings.detailTrailerEnabled {
                heroTrailerController.stop()
            }
            themeMusicController.setBlocked(heroTrailerController.isPlaying)
        }
        .onChange(of: heroTrailerController.isPlaying) { _, playing in
            themeMusicController.setBlocked(playing)
        }
        .onChange(of: activeDestinationKey) {
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
        let discovered = await discovery.libraryDiscovery(from: scopedAccounts)
        guard revision == libraryReloadRevision else { return }
        librariesStore.finishRefresh(
            with: discovered.libraries,
            unreachableAccountIDs: discovered.unreachableAccountIDs
        )
    }

    @MainActor
    private func scheduleLibraryReloadFromCurrentScope(changedAccountID: String) {
        libraryReloadRevision += 1
        let revision = libraryReloadRevision
        librariesStore.beginRefresh(accountIDs: [changedAccountID])
        Task { @MainActor in
            await Task.yield()
            let discovered = await discovery.libraryDiscovery(from: currentAccounts())
            guard revision == libraryReloadRevision else { return }
            librariesStore.finishRefresh(
                with: discovered.libraries,
                unreachableAccountIDs: discovered.unreachableAccountIDs
            )
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
