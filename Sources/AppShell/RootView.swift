#if canImport(SwiftUI)
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import FeatureProfiles
import CrashReporting
import FeatureAuth
import FeatureDiscovery
import FeatureDiscoveryCore
import FeatureHome
import FeaturePlayback
import FeatureSettings
import FeatureSyncCloud
import MetadataKit

/// Composes the identity that scopes the Home tab subtree — and the retained
/// ``HomeHeroRuntimeState`` it owns — to the active profile and Plex Home-user
/// generation. A change to either forces SwiftUI to tear down and rebuild
/// `MainTabView`, resetting the retained hero runtime, so watched overlays and
/// curated items from one profile can never leak into another. Extracted as a
/// pure function so this profile-isolation invariant is locked by a test.
enum HomeRuntimeScope {
    static func identityKey(profileID: String, plexPlaybackIdentityKey: String) -> String {
        "\(profileID)#\(plexPlaybackIdentityKey)"
    }

    static func accountScopeKey(_ accounts: [Account]) -> String {
        accounts
            .map { "\($0.id)#\($0.credentialRevision.rawValue.uuidString)" }
            .sorted()
            .joined(separator: "|")
    }

    /// The identity of the Home/Search subtree: which accounts AND which profile.
    ///
    /// The profile half is the point. `accountScopeKey` alone was the `.id()` of
    /// both tabs, so switching between two profiles that share the same servers —
    /// the normal case in a household — produced an unchanged key, SwiftUI kept
    /// the subtree, and the cached `HomeViewModel` went on serving the previous
    /// profile's content. The watchlist row was the visible symptom; every
    /// curated row had the same problem.
    static func homeScopeKey(profileID: String, accounts: [Account]) -> String {
        "\(profileID)|" + accountScopeKey(accounts)
    }
}

/// Top-level view that renders one screen per `SessionState`.
public struct RootView: View {
    @State private var appState: AppState
    @State private var showSyncReceive = false
    @State private var showSyncReceiveFromSettings = false
    /// A just-set-up profile whose PIN is being chosen.
    /// Identifies the server awaiting an identity choice, for `.fullScreenCover(item:)`.
    private struct PendingIdentityAccount: Identifiable { let id: String }

    /// Library discovery for the setup step's cover.
    @State private var setupLibraries = ProfileSetupLibrariesLoader()
    @State private var showSyncSend = false
    /// Home's view model, owned here because this is the highest view whose
    /// identity is genuinely stable for the signed-in session. Kept out of the
    /// tab tree so a `TabView` re-host cannot discard it mid-load; see
    /// ``LazyViewState`` for the measurements that forced this.
    @State private var homeViewModelBox = LazyViewState<HomeViewModel>()
    /// The device appearance, mirrored into state by `ColorSchemeMirror` rather
    /// than read from the environment here.
    ///
    /// Reading `@Environment(\.colorScheme)` in this view meant every appearance
    /// change re-evaluated RootView — and RootView is the root, so that cascaded
    /// through MainTabView, HomeTab and a detail page's whole subtree. Measured on
    /// the Apple TV at 861ms of blocked main thread, arriving with no relation to
    /// anything the viewer had done. Mirrored into `@State` and written only when
    /// the value genuinely differs, so a re-reported appearance costs nothing.
    @State private var systemColorScheme: ColorScheme = .dark
    /// The reader's text size. Feeds `PlozzMetrics` so the shared type/geometry
    /// table rebuilds when it changes (see where the metrics are injected below).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The OS-level Reduce Transparency setting, resolved against the active
    /// profile's in-app "Transparency (liquid glass)" preference (Settings ▸
    /// Appearance) and injected as `\.plozzReduceTransparency`. `tvOS Default`
    /// follows this OS value; `On` forces glass; `Off` forces solid.
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    /// Whether this device, playing whatever is playing, can afford glass.
    ///
    /// Owned here so a change reaches every surface at once, and injected so the
    /// player can raise and lower it without reaching back up through the app.
    @State private var glassPerformance = GlassPerformanceModel()
    /// Window-level black veil that survives the player's dismiss into Home so it
    /// can cover the TV's *physical* HDR/DV → SDR panel switch (which on some TVs
    /// lags ~1s behind tvOS's `displayDidSettle`). Injected into the environment so
    /// `PlayerView` can `engage()` it on exit; rendered as the topmost overlay here.
    @State private var displayVeil = DisplayVeilModel()

    /// Owns the opt-in crash reporter. Created once from the DSN baked into this
    /// build (empty ⇒ a true no-op). Started/stopped in response to the app-wide
    /// consent in `appState.crashReportingModel` — nothing is sent unless the user
    /// has opted in AND a DSN is present.
    @State private var crashReporting = CrashReportingController()

    /// Maps the active content identity (profile + accounts + Plex Home-user
    /// generation) to one scoped detail-snapshot cache, memoized for the app's
    /// lifetime so every detail destination under the same identity shares one
    /// instance and a switch of identity reads from a different on-disk scope.
    @State private var detailCacheFactory = DetailSnapshotCacheFactory()

    @MainActor
    public init(appState: AppState? = nil) {
        _appState = State(initialValue: appState ?? AppState())
    }

    /// The name THIS device holds for the offer's requested account. Since a per-server
    /// offer is only surfaced when this device has that account, this resolves the name
    /// locally rather than trusting the rendezvous-supplied string.
    private var syncSetupOfferServerName: String? {
        guard let requested = appState.cloudSyncUI.pendingSyncSetupOffer?.requestedAccountID else { return nil }
        return appState.accountsProviders.accounts.first(where: { $0.id == requested })?.server.name
    }

    /// Title for the same-Apple-ID setup offer alert. Names the specific server when
    /// the offering device asked for just one (per-server "set up with other device"),
    /// else falls back to the device-level framing.
    private var syncSetupOfferTitle: LocalizedStringResource {
        let device = appState.cloudSyncUI.pendingSyncSetupOffer?.deviceName ?? "your device"
        if let server = syncSetupOfferServerName {
            return "Set up “\(server)” on “\(device)”?"
        }
        return "Set up “\(device)”?"
    }

    /// The palette for the currently-selected theme. `.system` resolves against
    /// `systemColorScheme` — which stays the TRUE device scheme because we no
    /// longer force `preferredColorScheme` (that override polluted every colour-
    /// scheme source, incl. `@Environment` and the screen trait). We instead push
    /// the effective scheme DOWN via `.environment(\.colorScheme,)`, which never
    /// propagates back up to pollute this read. Re-resolves when the chosen theme
    /// or the device appearance changes.
    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(for: appState.profileSettings.themeModel.theme, systemColorScheme: systemColorScheme)
    }

    /// Reconcile the crash reporter with the current opt-in consent. Safe to call
    /// repeatedly: starts on the first opt-in, stops on opt-out, no-op otherwise
    /// (and always a no-op when the build has no DSN).
    ///
    /// DEBUG: honours `PLOZZ_FORCE_CRASH_REPORTING=1` in the environment to force
    /// the reporter on regardless of the persisted opt-in, so a crash-hunt build
    /// can capture a backtrace without navigating Settings. Off by default (the
    /// env var is unset in normal runs), so this changes no shipped behavior; it
    /// still no-ops when the build has no DSN. Mirrors the env-gated PLZHFOCUS
    /// diagnostics pattern.
    private func reconcileCrashReporting() {
        let forced = ProcessInfo.processInfo.environment["PLOZZ_FORCE_CRASH_REPORTING"] == "1"
        crashReporting.apply(
            enabled: appState.crashReportingModel.settings.isEnabled || forced,
            context: makeCrashContext()
        )
    }

    /// Non-secret context tagged onto crash reports: coarse provider *kinds*
    /// (Jellyfin/Plex), version/build/tvOS/device — never server names or tokens.
    private func makeCrashContext() -> CrashReportContext {
        var seen = Set<String>()
        let providers = appState.accountsProviders.accounts
            .map { $0.server.provider.displayName }
            .filter { seen.insert($0).inserted }
        return CrashReportContext.make(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz",
            version: AppInfo.version,
            build: AppInfo.build,
            providers: providers
        )
    }

    /// The identity of the whole signed-in subtree. Logged under the diagnostic
    /// flag because a change here throws away every `@State` below it — including
    /// Home's view model and its in-flight load.
    private var rootScopeIdentity: String {
        let profile = appState.profilesModel.activeProfile
        let accounts = appState.accountsProviders.homeAccounts.map(\.account)
        return HomeRuntimeScope.identityKey(
            profileID: profile.id,
            plexPlaybackIdentityKey: profile.plexPlaybackIdentityKey(for: accounts)
        )
    }

    public var body: some View {
        let _ = plozzPrintChanges { Self._printChanges() }
        // Read the PIN request HERE so the @Observable system registers it
        // as a dependency of body. The sheet's Binding closures aren't
        // tracked, so without this body never re-evaluates when the request
        // clears and the sheet stays up after a successful PIN.
        // Profile setup renders Plex PIN entry inside its own full-page flow.
        // Letting this root-level cover compete with the setup cover tears the
        // latter down and briefly exposes Home between "Watching as" and the PIN.
        let pinRequest = appState.profileFlow.pendingSetupProfile == nil
            ? appState.plexHomeUsers.pendingPlexPINRequest
            : nil
        return Group {
            switch appState.state {
            case .launching:
                LaunchView()

            case let .onboarding(step, canReturnToApp):
                OnboardingFlowView(
                    appState: appState,
                    step: step,
                    canReturnToApp: canReturnToApp,
                    deviceColorScheme: systemColorScheme,
                    onSetUpFromAnotherDevice: canReturnToApp ? nil : { showSyncReceive = true }
                )
                .fullScreenCover(isPresented: $showSyncReceive) {
                    SyncSetupReceiveView(appState: appState) { showSyncReceive = false }
                }

            case .ready:
                ZStack {
                if appState.profileFlow.isChoosingProfile {
                    ProfileSelectionView(appState: appState, canCancel: appState.profileFlow.isProfileSelectionCancelable)
                        .transition(.opacity)
                } else {
                    let accounts = appState.accountsProviders.homeAccounts
                    if !accounts.isEmpty {
                    let detailCache = detailCacheFactory.cache(
                        for: DetailSnapshotCacheScope(
                            profileID: appState.profilesModel.activeProfileID,
                            identityMaterial: HomeRuntimeScope.identityKey(
                                profileID: appState.profilesModel.activeProfileID,
                                plexPlaybackIdentityKey: appState.profilesModel.activeProfile
                                    .plexPlaybackIdentityKey(for: accounts.map(\.account))
                            ) + "|" + HomeRuntimeScope.accountScopeKey(accounts.map(\.account))
                        )
                    )
                    // Hoisted into explicitly-typed locals so the (very large)
                    // MainTabView initializer stays within the Swift type-checker's
                    // time budget — inline trailing closures here tip it over.
                    // Explicitly typed, like its neighbours: this initializer is
                    // at the Swift type-checker's budget and an inline closure
                    // here tips it into "unable to type-check in reasonable time".
                    let createProfileForSetup: (ProfileDraft) -> Void = { draft in
                        appState.createProfileForSetup(draft, isKids: false)
                    }
                    let debugActions = DebugSettingsActions(
                        resetToFirstRun: { appState.resetToFirstRunForDebugging() },
                        eraseICloud: { appState.eraseEverythingFromICloudForDebugging() }
                    )
                    let syncRepairActions = SyncRepairActions(
                        redownload: { appState.redownloadCloudSync() },
                        reset: { appState.resetCloudSync() }
                    )
                    // Per-profile language wraps only the profile-scoped subtree.
                    // The root AppLanguageScope stays the device-level default,
                    // because onboarding and the profile picker are shown BEFORE
                    // there is a profile whose language we could honour.
                    AppLanguageScope(model: appState.profileSettings.appLanguageModel) {
                    MainTabView(
                        accounts: accounts,
                        detailSnapshotCache: detailCache,
                        currentAccounts: { appState.accountsProviders.homeAccounts },
                        networkFileResolver: appState.mediaShare.networkFileResolver,
                        authenticatedHTTPResolver: appState.authenticatedHTTPResolver,
                        offlinePlaybackResolver: appState.offlinePlaybackResolver,
                        profileSettings: appState.profileSettings,
                        syncServices: SyncServices(
                            ratingsProvider: appState.ratingsProvider,
                            trakt: appState.traktService,
                            simkl: appState.simklService,
                            seer: appState.seerService,
                            anilist: appState.anilistService,
                            mal: appState.malService,
                            lastfm: appState.lastfmService
                        ),
                        seriesTrackStore: SeriesTrackPreferenceStore(namespace: appState.profilesModel.activeNamespace),
                        crashReportingModel: appState.crashReportingModel,
                        crashReportingConfigured: crashReporting.isConfigured,
                        shareScanStatusModel: appState.mediaShare.scanStatus,
                        audioController: appState.audioController,
                        homeLayoutStore: HomeLayoutStore(namespace: appState.profilesModel.activeNamespace),
                        homeContentStore: HomeContentStore(namespace: appState.profilesModel.activeNamespace),
                        mediaItemActionHandler: appState.mediaItemActionHandler,
                        enqueueWatchMutation: { appState.enqueueWatchMutation($0) },
                        // These bridge closures are `@Sendable` (the player may invoke
                        // them off the main actor), but every `appState` watch method is
                        // `@MainActor`-isolated. Hop to the main actor so the calls are
                        // data-race-safe. The hop is semantically free: each method's real
                        // work is already async (an enqueue+drain on the reconciler actor),
                        // and the reconciler's newest-wins `capturedAt` clock tolerates the
                        // ordering.
                        watchBridge: WatchOutboxBridge(
                            beginLiveSession: { accountID, itemID in
                                Task { @MainActor in
                                    appState.beginLiveWatchSession(accountID: accountID, itemID: itemID)
                                }
                            },
                            finishPlayback: { accountID, itemID, watchedPercent, mutation in
                                Task { @MainActor in
                                    appState.finishLiveWatchSession(accountID: accountID, itemID: itemID, watchedPercent: watchedPercent, mutation: mutation)
                                }
                            },
                            checkpoint: { mutation in
                                Task { @MainActor in
                                    appState.checkpointWatchState(mutation: mutation)
                                }
                            },
                            crossServerSync: { [namespace = appState.profilesModel.activeNamespace] in
                                PlaybackSettingsStore.currentSyncAcrossServers(namespace: namespace)
                            }
                        ),
                        pendingWatchMutations: { await appState.pendingWatchMutations() },
                        appliedWatchRecency: { await appState.appliedWatchRecency() },
                        displayAccounts: appState.accountsProviders.accounts,
                        activeAccountID: appState.accountsProviders.primaryActiveAccount?.id,
                        profiles: appState.profilesModel.profiles,
                        activeProfile: appState.profilesModel.activeProfile,
                        askProfileOnStartup: appState.profilesModel.askProfileOnStartup,
                        homeRuntime: HomeTabRuntime(
                            homeViewModel: homeViewModelBox,
                            scopeKey: HomeRuntimeScope.homeScopeKey(
                                profileID: appState.profilesModel.activeProfileID,
                                accounts: accounts.map(\.account)
                            ),
                            pendingPlay: appState.pendingPlay
                        ),
                        isAccountIncludedInActiveProfile: { appState.profileFlow.isAccountIncludedInActiveProfile($0) },
                        onSetAccountIncluded: { appState.profileFlow.setAccount($0, includedInActiveProfile: $1) },
                        onSetAskProfileOnStartup: { appState.profileFlow.setAskProfileOnStartup($0) },
                        onSaveProfile: { appState.profileFlow.saveProfile($0) },
                        onCreateProfile: createProfileForSetup,
                        onUpdateProfileCosmetics: { appState.profileFlow.updateProfileCosmetics($0) },
                        onDeleteProfile: { appState.profileFlow.removeProfile(id: $0) },
                        onAddAccount: { appState.addAccount() },
                        onAddUser: { appState.selectServer($0) },
                        onRemoveAccount: { appState.removeAccount(id: $0.id) },
                        onRemoveAccountEverywhere: { appState.removeAccountEverywhere(id: $0.id) },
                        offersRemoveEverywhere: appState.offersRemoveEverywhere,
                        onRescanShare: { appState.mediaShare.rescanShare(accountID: $0) },
                        onPollShares: { appState.mediaShare.pollSharesForChanges() },
                        onSignOutAll: { appState.signOutAll() },
                        onSwitchProfile: { appState.profileFlow.requestProfileSelection() },
                        debugActions: debugActions,
                        plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                        onSelectPlexHomeUser: { appState.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: $0, user: $1) },
                        onSetProfileLock: { appState.setLock($1, forProfile: $0) },
                        onSetKidsProfile: { appState.setKidsProfile($1, forProfile: $0) },
                        isProfileUnlocked: { appState.profileFlow.isUnlockedThisRun($0) },
                        onProfileUnlocked: { appState.profileFlow.noteUnlocked($0) },
                        onSetSeerrUser: { appState.setSeerrUserForProfile(profileID: $0, user: $1) },
                        metadataSettings: appState.makeMetadataSettingsDependencies(),
                        identitySources: appState.identityIndex.identitySourcesProvider,
                        onWarmIdentityIndex: { appState.identityIndex.warmIdentityIndex() },
                        onSetUpAnotherDevice: { showSyncSend = true },
                        syncEnabled: appState.syncSetup.isEnabled,
                        onSetSyncEnabled: { appState.setSyncSetupEnabled($0) },
                        // A closure, so the CloudSyncStatus properties are read
                        // in the Settings row that shows them. Reading them here
                        // subscribed the ROOT of the app to a model that ticks
                        // through every sync, and a root re-render dirties every
                        // view below it — the widest possible invalidation.
                        syncStatusSummary: SyncStatusProvider { Self.syncStatusText(appState.cloudSyncStatus) },
                        onSyncNow: { appState.syncCloudNow() },
                        syncRepair: syncRepairActions,
                        pendingSyncedServers: appState.cloudSyncUI.pendingSyncedServers,
                        onIgnorePendingServer: { appState.ignorePendingSyncedServer($0) },
                        onSetUpFromAnotherDevice: { showSyncReceiveFromSettings = true }
                    )
                    .id(rootScopeIdentity)
                    .transition(.opacity)
                    }
                    }
                }
                }
                .animation(.easeInOut(duration: 0.5), value: appState.profileFlow.isChoosingProfile)

            case let .failed(error, _):
                FailureView(message: error.userMessage) {
                    appState.retry()
                }
            }
        }
        .background { AppBackground(palette: resolvedPalette) }
        .environment(\.themePalette, resolvedPalette)
        // `dynamicTypeSize` is read here on purpose: PlozzMetrics samples its
        // typography once at construction, so this dependency is what makes the
        // whole table rebuild when the reader changes their text size. Without it
        // the sizes stay frozen at whatever they were when the app launched.
        .environment(
            \.plozzMetrics,
            PlozzMetrics(
                density: appState.profileSettings.uiDensityModel.density,
                dynamicTypeSize: dynamicTypeSize
            )
        )
        .environment(\.plozzCardStyle, appState.profileSettings.cardStyleModel.style)
        .environment(\.plozzWatchStatusIndicator, appState.profileSettings.watchStatusIndicatorModel.indicator)
        // Read by the corner mark on a card whose title isn't in the library:
        // connected turns "not yours" into "you can ask for this". Injected here
        // rather than passed down because the mark is drawn beneath every row,
        // grid and shelf in the app.
        .environment(\.plozzSeerConnected, appState.seerService.isConfigured)
        .environment(\.plozzNavigationStyle, appState.profileSettings.navigationStyleModel.style)
        // Accessibility and user intent only. Performance does NOT enter here:
        // this reaches every glass surface in the app, including controls small
        // enough that their backdrop sample costs nothing worth reclaiming.
        .environment(
            \.plozzReduceTransparency,
            appState.profileSettings.transparencyModel.preference.reducesTransparency(
                systemReduceTransparency: systemReduceTransparency
            )
        )
        // The same, plus performance — read by panels and cards, whose backdrop
        // sample is the whole reason the frame rate suffers.
        .environment(
            \.plozzReducePanelGlass,
            appState.profileSettings.transparencyModel.preference.reducesTransparency(
                systemReduceTransparency: systemReduceTransparency,
                performance: glassPerformance.budget
            )
        )
        // So a hairline tuned against an SDR backdrop can compensate for SDR
        // white being mapped brighter once the panel switches to HDR.
        .environment(\.plozzHDRDisplayActive, glassPerformance.budget.contentIsHDR)
        .environment(glassPerformance)
        .environment(displayVeil)
        // Push the theme's effective scheme DOWN into the tree instead of forcing
        // it on the window via `preferredColorScheme`. A downward environment value
        // themes SwiftUI content (materials, text, symbols) without propagating up
        // to override the window — so `systemColorScheme` above stays the real
        // device scheme and `.system` can follow it (and switching away from a
        // forced scheme never gets stuck).
        .environment(\.colorScheme, resolvedPalette.isLight ? .light : .dark)
        .transientStatusOverlay(
            presenter: appState.transientStatusPresenter,
            isLightSurface: resolvedPalette.isLight
        )
        // One cover for the whole access gate. Two separate covers dismissed the
        // profile PIN to Home, then presented the Plex PIN — flashing Home as if
        // access had been granted. This cover stays opaque and switches its
        // content in place.
        .fullScreenCover(isPresented: Binding(
            get: {
                appState.profileFlow.pendingLockedProfile != nil || pinRequest != nil
            },
            set: { presented in
                if !presented {
                    appState.profileFlow.cancelProfileLockPrompt()
                    appState.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )) {
            ProfileAccessGateView(appState: appState)
        }
        // Turning a server ON for a profile asks the same question setup asks:
        // who does this profile watch as there? Without it the watchlist import
        // reads that server as the account owner and quietly pulls their list
        // into, say, a child's profile.
        .fullScreenCover(item: Binding(
            get: { appState.profileFlow.pendingIdentityAccountID.map(PendingIdentityAccount.init(id:)) },
            set: { if $0 == nil { appState.profileFlow.resolveIdentityPrompt(for: appState.profileFlow.pendingIdentityAccountID ?? "") } }
        )) { pending in
            ProfileServerIdentityPromptView(
                appState: appState,
                accountID: pending.id,
                onFinish: { appState.profileFlow.resolveIdentityPrompt(for: pending.id) }
            )
        }
        // Resumes setup that was abandoned part-way — quit mid-flow, or synced
        // from a device where it was never finished. The gate is persisted, so a
        // profile left behind it would otherwise never import a watchlist at all.
        .task { appState.profileFlow.resumeSetupIfNeeded() }
        // A newly created profile's setup step: which servers, who it watches as,
        // which libraries. Presented HERE rather than by whatever created the
        // profile — creating one switches into it, which dismisses the picker, so
        // a cover owned by the picker would be torn down before it appeared.
        .fullScreenCover(
            item: Binding(
                get: { appState.profileFlow.pendingSetupProfile },
                set: { if $0 == nil { appState.profileFlow.completeSetup(for: appState.profilesModel.activeProfileID) } }
            )
        ) { profile in
            ProfileSetupFlowView(
                appState: appState,
                profile: profile,
                librariesStore: setupLibraries,
                deviceColorScheme: systemColorScheme
            )
        }
        // Last onboarding step stays full-screen. An alert here exposed Home
        // underneath an unrelated setup question, making the flow feel finished
        // before it actually was.
        .fullScreenCover(
            item: Binding(
                get: { appState.profileFlow.pendingLockOfferProfile },
                set: { if $0 == nil { appState.profileFlow.dismissLockOffer() } }
            )
        ) { profile in
            ProfileLockOfferView(
                profile: profile,
                syncEnabled: SyncSetupFeatureFlag().isEnabled,
                onComplete: { lock in
                    appState.setLock(lock, forProfile: profile.id)
                    appState.profileFlow.dismissLockOffer()
                },
                onSkip: { appState.profileFlow.dismissLockOffer() }
            )
        }
        // One-time theme picker for a profile just created in-app (Settings →
        // "Add Profile"). The app has already switched to the new profile, so
        // this edits its per-profile theme; Continue dismisses into the app.
        .fullScreenCover(
            isPresented: Binding(
                get: { appState.profileFlow.isPickingThemeForNewProfile },
                set: { newValue in if !newValue { appState.finishNewProfileThemeSelection() } }
            ),
            onDismiss: { appState.profileFlow.presentPostThemeStep() }
        ) {
            SelectThemeView(
                appState: appState,
                onContinue: { appState.finishNewProfileThemeSelection() },
                deviceColorScheme: systemColorScheme
            )
        }
        .fullScreenCover(isPresented: $showSyncSend) {
            SyncSetupSendView(appState: appState) { showSyncSend = false }
        }
        .fullScreenCover(isPresented: $showSyncReceiveFromSettings) {
            SyncSetupReceiveView(appState: appState) {
                showSyncReceiveFromSettings = false
                appState.refreshPendingSyncedServers()
            }
        }
        .alert(
            "New server from your other device",
            isPresented: Binding(
                get: { appState.cloudSyncUI.pendingServerPrompt != nil },
                set: { if !$0 { appState.clearPendingServerPrompt() } }
            ),
            presenting: appState.cloudSyncUI.pendingServerPrompt
        ) { descriptor in
            Button("Set Up") {
                appState.clearPendingServerPrompt()
                showSyncReceiveFromSettings = true
            }
            Button("Ignore", role: .destructive) {
                appState.ignorePendingSyncedServer(descriptor.id)
            }
            Button("Not Now", role: .cancel) {
                appState.clearPendingServerPrompt()
            }
        } message: { descriptor in
            Text("“\(descriptor.serverName)” is set up on another device. Sign in to watch it here — your login stays private to each device. You can also find it later under Settings ▸ iCloud Sync.")
        }
        .alert(
            syncSetupOfferTitle,
            isPresented: Binding(
                // Presentation is driven purely by pendingSyncSetupOffer; the two
                // buttons own confirm/decline, so the setter must NOT have a side
                // effect (that would double-fire and race the button action). tvOS
                // routes the Menu button to the .cancel role, so decline still runs.
                get: { appState.cloudSyncUI.pendingSyncSetupOffer != nil },
                set: { _ in }
            ),
            presenting: appState.cloudSyncUI.pendingSyncSetupOffer
        ) { _ in
            Button("Set Up") { appState.confirmSyncSetupOffer() }
            Button("Not Now", role: .cancel) { appState.declineSyncSetupOffer() }
        } message: { _ in
            Text(syncSetupOfferServerName != nil
                 ? "Sign this device in to “\(syncSetupOfferServerName!)”."
                 : "Send your servers and sign-in so it’s ready to watch.")
        }
        .onAppear {
            if case .launching = appState.state { appState.bootstrap() }
            appState.drainWatchOutbox()
            reconcileCrashReporting()
        }
        .onChange(of: appState.crashReportingModel.settings.isEnabled) { _, _ in
            reconcileCrashReporting()
        }
        // Scene-phase side effects live in a zero-size child, NOT here.
        //
        // Reading `@Environment(\.scenePhase)` in this view made every phase
        // change re-evaluate RootView — and RootView is the root, so that cascades
        // through MainTabView, HomeTab and the whole ItemDetailView subtree.
        // Measured on the Apple TV: 800ms-1s main-thread stalls, arriving well
        // after whatever the viewer had actually done. The phase is only ever used
        // to FIRE things, never to build anything, so nothing here needs to depend
        // on it.
        .background(
            ColorSchemeMirror { scheme in
                // Guarded: an unconditional assignment would reinstate the very
                // invalidation this exists to remove.
                if systemColorScheme != scheme { systemColorScheme = scheme }
            }
        )
        .background(
            ScenePhaseEffects(
                onBackgroundWorkAllowed: { allowed in
                    appState.mediaShare.setBackgroundWorkAllowed(allowed)
                },
                onBecameActive: {
                    appState.drainWatchOutbox()
                    // Pull the latest synced config when the app comes to the
                    // foreground (tvOS push is best-effort), so profile/setting
                    // changes made elsewhere show up promptly instead of waiting
                    // for a manual sync.
                    appState.syncCloudOnForeground()
                }
            )
        )
        .onOpenURL { appState.handle(url: $0) }
        // Window-level HDR/DV exit veil: a black layer above Home that the player
        // raises (via the injected `DisplayVeilModel`) just before it dismisses, so
        // black survives the dismiss and keeps covering the screen through the TV's
        // slow physical panel switch. Always returns to 0 (settle+buffer, no-settle
        // fallback, or the safety cap), so it can never strand the user on black.
        .overlay {
            Color.black
                .opacity(displayVeil.veilOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(displayVeil.veilOpacity > 0.01)
                // Snap to black *instantly* on engage (rising edge → no animation)
                // so the player's dismiss lands on an already-opaque window veil and
                // Home never shows through. Only the fade-OUT (falling edge, after
                // the panel settles) is animated.
                .animation(displayVeil.veilOpacity == 0 ? .easeInOut(duration: 0.4) : nil,
                           value: displayVeil.veilOpacity)
        }
        .modifier(RootDisplaySettleObserver { displayVeil.displayDidSettle() })
        // Per-profile Night Shift: a warm/dim screen tint that multiplies the
        // whole app (player included) on the active profile's schedule. Installed
        // at the app root so it floats above every screen and modal cover. The
        // model is rebuilt on profile switch by AppState, so each profile gets its
        // own tint without re-architecting this call site.
        .installNightShiftOverlay(appState.profileSettings.nightShiftModel)
    }

    /// Composes the sync status line as `Text` rather than a `String`. The
    /// diagnostic is a raw CloudKit message, so it stays verbatim; the wording
    /// around it stays a resource and is resolved at render time.
    private static func syncStatusText(_ status: CloudSyncStatus) -> Text {
        let parts = status.summaryLineParts
        var text = Text(parts.summary)
        if let diagnostic = parts.diagnostic {
            text = text + Text(verbatim: " · \(diagnostic)")
        }
        if let detail = parts.detail {
            text = text + Text(verbatim: "\n") + Text(detail)
        }
        return text
    }
}

private enum OnboardingPage: Equatable {
    case selectingServer(canReturnToApp: Bool)
    case authenticating(MediaServer)
    case selectPlexUser(PlexHomeUsersModel.PendingPlexUserSelection?)
    case selectLibraries
    case confirmProfile
    case selectSeerr
    case selectTheme

    init(
        step: OnboardingStep,
        canReturnToApp: Bool,
        plexUserSelection: PlexHomeUsersModel.PendingPlexUserSelection?
    ) {
        switch step {
        case .selectingServer:
            self = .selectingServer(canReturnToApp: canReturnToApp)
        case let .authenticating(server):
            self = .authenticating(server)
        case .selectPlexUser:
            self = .selectPlexUser(plexUserSelection)
        case .selectLibraries:
            self = .selectLibraries
        case .confirmProfile:
            self = .confirmProfile
        case .selectSeerr:
            self = .selectSeerr
        case .selectTheme:
            self = .selectTheme
        }
    }

    var order: Int {
        switch self {
        case .selectingServer: 0
        case .authenticating: 1
        case .selectPlexUser: 2
        case .selectLibraries: 3
        case .confirmProfile: 4
        case .selectSeerr: 5
        case .selectTheme: 6
        }
    }

    var transitionID: String {
        switch self {
        case let .selectingServer(canReturnToApp):
            "selectingServer-\(canReturnToApp)"
        case let .authenticating(server):
            "authenticating-\(server.id)"
        case let .selectPlexUser(selection):
            "selectPlexUser-\(selection?.accountID ?? "pending")"
        case .selectLibraries:
            "selectLibraries"
        case .confirmProfile:
            "confirmProfile"
        case .selectSeerr:
            "selectSeerr"
        case .selectTheme:
            "selectTheme"
        }
    }
}

private struct OnboardingFlowView: View {
    let appState: AppState
    let step: OnboardingStep
    let canReturnToApp: Bool
    let deviceColorScheme: ColorScheme
    var onSetUpFromAnotherDevice: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedPage: OnboardingPage
    @State private var pendingPage: OnboardingPage?
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var isTransitioning = false

    init(
        appState: AppState,
        step: OnboardingStep,
        canReturnToApp: Bool,
        deviceColorScheme: ColorScheme,
        onSetUpFromAnotherDevice: (() -> Void)? = nil
    ) {
        self.appState = appState
        self.step = step
        self.canReturnToApp = canReturnToApp
        self.deviceColorScheme = deviceColorScheme
        self.onSetUpFromAnotherDevice = onSetUpFromAnotherDevice
        _displayedPage = State(initialValue: OnboardingPage(
            step: step,
            canReturnToApp: canReturnToApp,
            plexUserSelection: appState.plexHomeUsers.pendingPlexUserSelection
        ))
    }

    var body: some View {
        ZStack {
            OnboardingPageContent(
                page: displayedPage,
                appState: appState,
                deviceColorScheme: deviceColorScheme,
                onSetUpFromAnotherDevice: onSetUpFromAnotherDevice
            )
            .id(displayedPage.transitionID)
            .geometryGroup()
            .transition(pageTransition)
            .allowsHitTesting(!isTransitioning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: currentPage) { _, newPage in
            enqueue(newPage)
        }
    }

    private var currentPage: OnboardingPage {
        OnboardingPage(
            step: step,
            canReturnToApp: canReturnToApp,
            plexUserSelection: appState.plexHomeUsers.pendingPlexUserSelection
        )
    }

    private var pageTransition: AnyTransition {
        OnboardingPageMotion.transition(
            direction: navigationDirection,
            reduceMotion: reduceMotion
        )
    }

    private func enqueue(_ page: OnboardingPage) {
        guard page != displayedPage || isTransitioning else { return }
        pendingPage = page
        guard !isTransitioning else { return }
        transitionToPendingPage()
    }

    private func transitionToPendingPage() {
        guard let nextPage = pendingPage else { return }
        pendingPage = nil
        guard nextPage != displayedPage else { return }

        let outgoingPage = displayedPage
        navigationDirection = direction(from: outgoingPage, to: nextPage)
        isTransitioning = true

        withAnimation(
            OnboardingPageMotion.animation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            displayedPage = nextPage
        } completion: {
            isTransitioning = false
            if pendingPage == displayedPage {
                pendingPage = nil
            }
            if pendingPage != nil {
                transitionToPendingPage()
            }
        }
    }

    private func direction(
        from oldPage: OnboardingPage,
        to newPage: OnboardingPage
    ) -> OnboardingNavigationDirection {
        newPage.order < oldPage.order ? .backward : .forward
    }
}

private struct OnboardingPageContent: View {
    let page: OnboardingPage
    let appState: AppState
    let deviceColorScheme: ColorScheme
    var onSetUpFromAnotherDevice: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch page {
        case let .selectingServer(canReturnToApp):
            AddAccountView(
                deviceID: appState.accountsProviders.deviceID,
                canReturnToApp: canReturnToApp,
                initialProvider: appState.pendingOnboardingProvider,
                signedInServers: appState.signedInServers,
                onMediaBrowserServerSelected: { server in appState.selectServer(server) },
                onPlexAuthenticated: { session in appState.didAuthenticatePlex(session) },
                onPlexAuthenticatedMany: { sessions in appState.didAuthenticatePlexMany(sessions) },
                onShareConfigured: { draft in
                    appState.didConfigureShare(
                        host: draft.host,
                        port: draft.port,
                        share: draft.share,
                        username: draft.username,
                        password: draft.password,
                        displayName: draft.displayName
                    )
                },
                onWebDAVShareConfigured: { config in
                    appState.didConfigureWebDAVShare(
                        baseURL: config.baseURL,
                        auth: config.auth,
                        trustPin: config.trustPin,
                        displayName: config.displayName
                    )
                },
                onMediaShareConfigured: { result in
                    switch result {
                    case let .nfs(config):
                        appState.didConfigureNFSShare(
                            host: config.host,
                            port: config.port,
                            exportPath: config.exportPath,
                            displayName: config.displayName
                        )
                    case let .sftp(config):
                        appState.didConfigureSFTPShare(
                            host: config.host,
                            port: config.port,
                            path: config.path,
                            username: config.username,
                            password: config.password,
                            hostKeyPin: config.hostKeyPin,
                            displayName: config.displayName
                        )
                    case let .ftp(config):
                        appState.didConfigureFTPShare(
                            baseURL: config.baseURL,
                            auth: config.auth,
                            trustPin: config.trustPin,
                            displayName: config.displayName
                        )
                    }

                },
                onCancel: { appState.cancelAuthentication() },
                onSetUpFromAnotherDevice: onSetUpFromAnotherDevice
            )

        case let .authenticating(server):
            if server.provider == .plex {
                ProgressView("Finishing Plex sign-in…")
                    .font(.title2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AuthView(
                    server: server,
                    deviceID: appState.accountsProviders.deviceID,
                    onAuthenticated: { session in appState.didAuthenticate(session) },
                    onCancel: { appState.cancelAuthentication() }
                )
            }

        case let .selectPlexUser(selection):
            if let selection {
                PlexUserSelectionView(
                    selection: selection,
                    onSelect: { user in appState.selectPlexUserDuringOnboarding(user) }
                )
            } else {
                LaunchView()
            }

        case .selectLibraries:
            SelectLibrariesView(appState: appState)

        case .confirmProfile:
            FirstRunProfileView(appState: appState)

        case .selectSeerr:
            ProfileSeerrSetupView(
                seer: appState.seerService,
                profile: appState.profilesModel.activeProfile,
                onSelect: { user in
                    appState.setSeerrUserForProfile(
                        profileID: appState.profilesModel.activeProfileID,
                        user: user
                    )
                },
                onContinue: { appState.completeFirstRunSeerrSetup() }
            )

        case .selectTheme:
            SelectThemeView(
                appState: appState,
                onContinue: { appState.finishThemeSelection() },
                deviceColorScheme: deviceColorScheme
            )
        }
    }
}

/// Keeps every detour from new-profile setup inside the setup cover.
///
/// Selecting a PIN-protected Plex user used to ask the ROOT to present another
/// cover, which replaced the setup cover and exposed Home during the hand-off.
/// Adding another user changed the session state underneath the unchanged setup
/// cover, so its auth screen existed but could never be seen. One full-page
/// switch here handles both: PIN, add-account onboarding, then back to Libraries.
private struct ProfileSetupFlowView: View {
    let appState: AppState
    let profile: Profile
    let librariesStore: ProfileSetupLibrariesLoader
    let deviceColorScheme: ColorScheme
    @State private var stage: ProfileSetupStage = .libraries

    private var setupPalette: ThemePalette {
        ThemePalette.palette(
            for: appState.profileSettings.themeModel.theme,
            systemColorScheme: deviceColorScheme
        )
    }

    var body: some View {
        ZStack {
            // Permanent cover backdrop. Every page change happens above this, so
            // even a frame with neither outgoing nor incoming content cannot
            // reveal the profile picker/Home below.
            AppBackground(palette: setupPalette)
            .ignoresSafeArea()

            ProfileSetupLibrariesView(
                scope: appState.profileLibrariesScope(librariesStore: librariesStore)
            ) {
                appState.completeProfileLibrariesInsideSetup(for: profile.id)
                stage = .seerr
            }
            .task { await librariesStore.reload(appState: appState) }
            .opacity(stage == .libraries ? 1 : 0)
            .allowsHitTesting(stage == .libraries && !showsDetour)

            if let request = appState.plexHomeUsers.pendingPlexPINRequest {
                PlexPINEntryView(
                    appState: appState,
                    userName: request.homeUserName,
                    avatarURLString: request.homeUserAvatarURL,
                    dismissOnSuccess: false,
                    onSubmit: { appState.plexHomeUsers.submitPlexPIN($0) },
                    onCancel: { appState.plexHomeUsers.cancelPlexPIN() }
                )
            } else if case let .onboarding(step, canReturnToApp) = appState.state {
                ZStack {
                    // Embedded onboarding normally inherits RootView's backdrop.
                    // Here it is an overlay inside another cover, so own an
                    // opaque surface across every transition frame.
                    AppBackground(palette: setupPalette).ignoresSafeArea()
                    OnboardingFlowView(
                        appState: appState,
                        step: step,
                        canReturnToApp: canReturnToApp,
                        deviceColorScheme: deviceColorScheme
                    )
                }
            } else {
                stageContent
            }
        }
        // Explicitly disable implicit fades between stage enum values.
        .transaction { $0.animation = nil }
    }

    private var showsDetour: Bool {
        if appState.plexHomeUsers.pendingPlexPINRequest != nil { return true }
        if case .onboarding = appState.state { return true }
        return false
    }

    @ViewBuilder
    private var stageContent: some View {
        let liveProfile = appState.profilesModel.profiles
            .first(where: { $0.id == profile.id }) ?? profile
        switch stage {
        case .libraries:
            EmptyView()
        case .seerr:
            ProfileSeerrSetupView(
                seer: appState.seerService,
                profile: liveProfile,
                onSelect: { user in
                    appState.setSeerrUserForProfile(profileID: profile.id, user: user)
                },
                onContinue: { stage = .theme }
            )
        case .theme:
            SelectThemeView(
                appState: appState,
                onContinue: { stage = .lock },
                deviceColorScheme: deviceColorScheme
            )
        case .lock:
            ProfileLockOfferView(
                profile: liveProfile,
                syncEnabled: SyncSetupFeatureFlag().isEnabled,
                onComplete: { lock in
                    appState.setLock(lock, forProfile: profile.id)
                    appState.finishProfileSetupFlow()
                },
                onSkip: { appState.finishProfileSetupFlow() }
            )
        }
    }
}

private enum ProfileSetupStage {
    case libraries
    case seerr
    case theme
    case lock
}

/// Persistent profile-entry gate: profile PIN first, Plex PIN second when needed.
///
/// `expectsTwoPINs` is captured when the cover opens, before the profile switch
/// clears `pendingLockedProfile`, so step 2 still knows it belongs to a chain.
private struct ProfileAccessGateView: View {
    let appState: AppState

    @Environment(\.themePalette) private var palette
    @State private var expectsTwoPINs: Bool

    init(appState: AppState) {
        self.appState = appState
        let profile = appState.profileFlow.pendingLockedProfile
        _expectsTwoPINs = State(initialValue:
            profile?.isLocked == true
                && profile?.lock?.matchesPlexPIN != true
                && profile?.playsAsPINProtectedPlexUser == true
        )
    }

    var body: some View {
        ZStack {
            // Remains behind BOTH steps, so even the content cross-fade can never
            // reveal Home.
            AppBackground(palette: palette).ignoresSafeArea()

            if let profile = appState.profileFlow.pendingLockedProfile {
                ProfileLockPINView(
                    profile: profile,
                    errorMessage: appState.profileFlow.profileLockError,
                    isSyncEnabled: SyncSetupFeatureFlag().isEnabled,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 1, total: 2)
                        : nil,
                    onSubmit: { appState.profileFlow.submitProfileLockPIN($0) },
                    onCancel: { appState.profileFlow.cancelProfileLockPrompt() }
                )
                .id("profile-pin")
                .transition(.opacity)
            } else if let request = appState.plexHomeUsers.pendingPlexPINRequest {
                PlexPINEntryView(
                    appState: appState,
                    userName: request.homeUserName,
                    avatarURLString: request.homeUserAvatarURL,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 2, total: 2)
                        : nil,
                    dismissOnSuccess: false,
                    onSubmit: { appState.plexHomeUsers.submitPlexPIN($0) },
                    onCancel: { appState.plexHomeUsers.cancelPlexPIN() }
                )
                .id("plex-pin")
                .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: 0.2),
            value: appState.profileFlow.pendingLockedProfile?.id
        )
    }
}

/// Observes the tvOS display manager at the app root and forwards mode-switch-end
/// to the window-level `DisplayVeilModel`, so the exit veil can time its hold off
/// the *reported* settle even after the player has been dismissed. A no-op on
/// platforms without `AVDisplayManager` (e.g. macOS).
private struct RootDisplaySettleObserver: ViewModifier {
    let onSettle: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onReceive(
            NotificationCenter.default.publisher(for: .AVDisplayManagerModeSwitchEnd)
        ) { _ in
            onSettle()
        }
        #else
        content
        #endif
    }
}

/// Modal PIN entry shown when switching to a profile mapped to a PIN-protected
/// Plex Home user. The PIN is passed straight to Plex and never stored.
///
/// tvOS lacks a numeric keyboard (`.keyboardType(.numberPad)` is ignored), so
/// a SecureField forces the full QWERTY remote keyboard for a 4-digit code.
/// Layout mirrors Plex's own tvOS PIN screen: the Home user's avatar (with a
/// small lock badge) and name at the top, an "PIN" pill that fills as digits
/// are entered, and a single horizontal strip of digit keys + delete below.
/// One axis of focus is what the Siri remote handles best.
private struct PlexPINEntryView: View {
    let appState: AppState
    let userName: String
    let avatarURLString: String?
    var sequenceStep: PINSequenceStep? = nil
    var dismissOnSuccess: Bool = true
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting: Bool = false

    var body: some View {
        // Track the request directly so a successful switch (which clears
        // pendingPlexPINRequest on AppState) re-evaluates THIS view and triggers
        // the onChange-based dismiss below. Belt-and-suspenders dismissal that
        // does NOT rely on the outer cover binding tracking anything — call
        // dismiss() ourselves from inside the cover.
        let pendingRequest = appState.plexHomeUsers.pendingPlexPINRequest
        return PINEntryScaffold(
            title: "Enter your Plex PIN",
            name: userName,
            errorMessage: appState.plexHomeUsers.plexPINError,
            isSubmitting: isSubmitting,
            sequenceStep: sequenceStep,
            onSubmit: { pin in
                // Flip isSubmitting so the user sees a spinner rather than "four
                // dots and nothing happens" while the network round-trip runs.
                PlozzLog.auth.debug("PIN auto-submit at 4 digits")
                isSubmitting = true
                onSubmit(pin)
            },
            onCancel: onCancel
        ) {
            PINBadge {
                if let url = avatarURLString.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        default:
                            PlexPINFallbackGlyph()
                        }
                    }
                } else {
                    PlexPINFallbackGlyph()
                }
            }
            .frame(width: PINLayout.badgeSize, height: PINLayout.badgeSize)
        }
        .onChange(of: appState.plexHomeUsers.plexPINError) { _, newValue in
            // Wrong-PIN response: drop the submitting state so the user can retry
            // (the scaffold clears the entered digits off the same signal).
            if newValue != nil { isSubmitting = false }
        }
        .onChange(of: pendingRequest?.id) { _, newValue in
            // The cover's outer Binding tracking has been flaky on tvOS — call
            // dismiss() directly from inside the cover when AppState clears the
            // pending request (success path). This is the authoritative signal
            // that the PIN was accepted.
            if newValue == nil, dismissOnSuccess {
                PlozzLog.auth.debug("pendingPlexPINRequest cleared — calling dismiss()")
                dismiss()
            }
        }
    }
}

/// Person glyph shown when no Plex thumb is cached for the Home user.
private struct PlexPINFallbackGlyph: View {
    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: PINLayout.badgeSize * 0.5))
            .plozzForeground(.secondary)
    }
}

/// Brief splash while we check for a stored session.
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text(verbatim: "Plozz")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let message: LocalizedStringResource
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif

/// Zero-size observer that turns scene-phase transitions into callbacks.
///
/// Exists so that reading `scenePhase` invalidates only this view instead of the
/// one it hangs off. A `@State`-free `View` whose body is `Color.clear` costs
/// nothing to rebuild, where re-evaluating the app's root costs the whole tree —
/// including a detail page's full subtree, measured at 800ms-1s on the Apple TV.
private struct ScenePhaseEffects: View {
    let onBackgroundWorkAllowed: (Bool) -> Void
    let onBecameActive: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .task(id: scenePhase) {
                onBackgroundWorkAllowed(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { onBecameActive() }
            }
    }
}

/// Zero-size mirror of the device's colour scheme.
///
/// Same shape as `ScenePhaseEffects`: the environment read lives in a view whose
/// rebuild is free, instead of in the root, whose rebuild is the whole app.
private struct ColorSchemeMirror: View {
    let onChange: (ColorScheme) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .task(id: colorScheme) { onChange(colorScheme) }
    }
}
