#if canImport(SwiftUI)
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting
import FeatureAuth
import FeatureDiscovery
import FeatureDiscoveryCore
import FeatureHome
import FeaturePlayback
import MetadataKit

/// Composes the identity that scopes the Home tab subtree — and the retained
/// ``HomeHeroRuntimeState`` it owns — to the active profile and Plex Home-user
/// generation. A change to either forces SwiftUI to tear down and rebuild
/// `MainTabView`, resetting the retained hero runtime, so watched overlays and
/// curated items from one profile can never leak into another. Extracted as a
/// pure function so this profile-isolation invariant is locked by a test.
enum HomeRuntimeScope {
    static func identityKey(profileID: String, plexIdentityGeneration: Int) -> String {
        "\(profileID)#\(plexIdentityGeneration)"
    }

    static func accountScopeKey(_ accounts: [Account]) -> String {
        accounts
            .map { "\($0.id)#\($0.credentialRevision.rawValue.uuidString)" }
            .sorted()
            .joined(separator: "|")
    }
}

/// Top-level view that renders one screen per `SessionState`.
public struct RootView: View {
    @State private var appState: AppState
    @State private var showSyncReceive = false
    @State private var showSyncSend = false
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// The OS-level Reduce Transparency setting, resolved against the active
    /// profile's in-app "Transparency (liquid glass)" preference (Settings ▸
    /// Appearance) and injected as `\.plozzReduceTransparency`. `tvOS Default`
    /// follows this OS value; `On` forces glass; `Off` forces solid.
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
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

    public var body: some View {
        // Read the PIN request HERE so the @Observable system registers it
        // as a dependency of body. The sheet's Binding closures aren't
        // tracked, so without this body never re-evaluates when the request
        // clears and the sheet stays up after a successful PIN.
        let pinRequest = appState.plexHomeUsers.pendingPlexPINRequest
        return Group {
            switch appState.state {
            case .launching:
                LaunchView()

            case let .onboarding(step, canReturnToApp):
                OnboardingFlowView(
                    appState: appState,
                    step: step,
                    canReturnToApp: canReturnToApp,
                    deviceColorScheme: systemColorScheme
                )
                .overlay(alignment: .bottom) {
                    Button {
                        showSyncReceive = true
                    } label: {
                        Label("Set up from another device", systemImage: "qrcode")
                    }
                    .padding(.bottom, 40)
                }
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
                                plexIdentityGeneration: appState.plexHomeUsers.plexIdentityGeneration
                            ) + "|" + HomeRuntimeScope.accountScopeKey(accounts.map(\.account))
                        )
                    )
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
                        profilesEnabled: appState.profilesModel.profilesEnabled,
                        pendingPlayItemID: Binding(
                            get: { appState.pendingPlayItemID },
                            set: { appState.pendingPlayItemID = $0 }
                        ),
                        isAccountIncludedInActiveProfile: { appState.profileFlow.isAccountIncludedInActiveProfile($0) },
                        onSetAccountIncluded: { appState.profileFlow.setAccount($0, includedInActiveProfile: $1) },
                        onSetAskProfileOnStartup: { appState.profileFlow.setAskProfileOnStartup($0) },
                        onEnableProfiles: { appState.profileFlow.enableProfiles() },
                        onDisableProfiles: { appState.profileFlow.disableProfiles() },
                        onSaveProfile: { appState.profileFlow.saveProfile($0) },
                        onUpdateProfileCosmetics: { appState.profileFlow.updateProfileCosmetics($0) },
                        onDeleteProfile: { appState.profileFlow.removeProfile(id: $0) },
                        onAddAccount: { appState.addAccount() },
                        onRemoveAccount: { appState.removeAccount(id: $0.id) },
                        onRescanShare: { appState.mediaShare.rescanShare(accountID: $0) },
                        onSignOutAll: { appState.signOutAll() },
                        onSwitchProfile: { appState.profileFlow.requestProfileSelection() },
                        onResetToFirstRun: { appState.resetToFirstRunForDebugging() },
                        plexHomeUsersFetcher: { await appState.plexHomeUsers.plexHomeUsers(forAccountID: $0) },
                        onSelectPlexHomeUser: { appState.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: $0, user: $1) },
                        onSetSeerrUser: { appState.setSeerrUserForProfile(profileID: $0, user: $1) },
                        identitySources: appState.identityIndex.identitySourcesProvider,
                        onWarmIdentityIndex: { appState.identityIndex.warmIdentityIndex() },
                        onSetUpAnotherDevice: { showSyncSend = true }
                    )
                    .id(HomeRuntimeScope.identityKey(
                        profileID: appState.profilesModel.activeProfileID,
                        plexIdentityGeneration: appState.plexHomeUsers.plexIdentityGeneration
                    ))
                    .transition(.opacity)
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
        .environment(\.plozzMetrics, PlozzMetrics(density: appState.profileSettings.uiDensityModel.density))
        .environment(\.plozzCardStyle, appState.profileSettings.cardStyleModel.style)
        .environment(\.plozzWatchStatusIndicator, appState.profileSettings.watchStatusIndicatorModel.indicator)
        .environment(\.plozzNavigationStyle, appState.profileSettings.navigationStyleModel.style)
        .environment(\.plozzReduceTransparency, appState.profileSettings.transparencyModel.preference.reducesTransparency(systemReduceTransparency: systemReduceTransparency))
        .environment(displayVeil)
        // Push the theme's effective scheme DOWN into the tree instead of forcing
        // it on the window via `preferredColorScheme`. A downward environment value
        // themes SwiftUI content (materials, text, symbols) without propagating up
        // to override the window — so `systemColorScheme` above stays the real
        // device scheme and `.system` can follow it (and switching away from a
        // forced scheme never gets stuck).
        .environment(\.colorScheme, resolvedPalette.isLight ? .light : .dark)
        .fullScreenCover(item: Binding(
            get: { pinRequest },
            set: { newValue in if newValue == nil { appState.plexHomeUsers.dismissPlexPINIfPresented() } }
        )) { request in
            PlexPINEntryView(
                appState: appState,
                userName: request.homeUserName,
                avatarURLString: request.homeUserAvatarURL,
                onSubmit: { appState.plexHomeUsers.submitPlexPIN($0) },
                onCancel: { appState.plexHomeUsers.cancelPlexPIN() }
            )
        }
        // One-time theme picker for a profile just created in-app (Settings →
        // "Add Profile"). The app has already switched to the new profile, so
        // this edits its per-profile theme; Continue dismisses into the app.
        .fullScreenCover(isPresented: Binding(
            get: { appState.profileFlow.isPickingThemeForNewProfile },
            set: { newValue in if !newValue { appState.finishNewProfileThemeSelection() } }
        )) {
            SelectThemeView(
                appState: appState,
                onContinue: { appState.finishNewProfileThemeSelection() },
                deviceColorScheme: systemColorScheme
            )
        }
        .fullScreenCover(isPresented: $showSyncSend) {
            SyncSetupSendView(appState: appState) { showSyncSend = false }
        }
        .onAppear {
            if case .launching = appState.state { appState.bootstrap() }
            appState.drainWatchOutbox()
            reconcileCrashReporting()
        }
        .onChange(of: appState.crashReportingModel.settings.isEnabled) { _, _ in
            reconcileCrashReporting()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { appState.drainWatchOutbox() }
        }
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
}

private enum OnboardingPage: Equatable {
    case selectingServer(canReturnToApp: Bool)
    case authenticating(MediaServer)
    case selectPlexUser(PlexHomeUsersModel.PendingPlexUserSelection?)
    case selectLibraries
    case enableProfilesPrompt
    case confirmProfile
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
        case .enableProfilesPrompt:
            self = .enableProfilesPrompt
        case .confirmProfile:
            self = .confirmProfile
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
        case .enableProfilesPrompt: 4
        case .confirmProfile: 5
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
        case .enableProfilesPrompt:
            "enableProfilesPrompt"
        case .confirmProfile:
            "confirmProfile"
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedPage: OnboardingPage
    @State private var pendingPage: OnboardingPage?
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var isTransitioning = false

    init(
        appState: AppState,
        step: OnboardingStep,
        canReturnToApp: Bool,
        deviceColorScheme: ColorScheme
    ) {
        self.appState = appState
        self.step = step
        self.canReturnToApp = canReturnToApp
        self.deviceColorScheme = deviceColorScheme
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
                deviceColorScheme: deviceColorScheme
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
                onCancel: { appState.cancelAuthentication() }
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

        case .enableProfilesPrompt:
            EnableProfilesView(appState: appState)

        case .confirmProfile:
            FirstRunProfileView(appState: appState)

        case .selectTheme:
            SelectThemeView(
                appState: appState,
                onContinue: { appState.finishThemeSelection() },
                deviceColorScheme: deviceColorScheme
            )
        }
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
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var isSubmitting: Bool = false

    private static let pinLength = 4

    var body: some View {
        // Track the request directly so a successful switch (which clears
        // pendingPlexPINRequest on AppState) re-evaluates THIS view and
        // triggers the onChange-based dismiss below. Belt-and-suspenders
        // dismissal that does NOT rely on the outer cover binding tracking
        // anything — call dismiss() ourselves from inside the cover.
        let pendingRequest = appState.plexHomeUsers.pendingPlexPINRequest
        return ZStack {
            // Full-bleed dimmed backdrop so the PIN screen reads as a modal
            // OVER the app (like Plex does), not as an opaque context switch.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer(minLength: 0)
                avatarBadge
                Text(userName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    pinBoxes
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                // Reserve the error slot so the strip doesn't jump up/down
                // when an error appears/clears between attempts.
                Text(appState.plexHomeUsers.plexPINError ?? " ")
                    .font(.callout)
                    .foregroundStyle(appState.plexHomeUsers.plexPINError == nil ? Color.clear : .red)
                    .multilineTextAlignment(.center)
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.5 : 1.0)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onCancel)
        .onChange(of: appState.plexHomeUsers.plexPINError) { _, newValue in
            // Wrong-PIN response: clear the entered boxes + drop the submitting
            // state so the user can retry without first backspacing four times.
            if newValue != nil {
                pin = ""
                isSubmitting = false
            }
        }
        .onChange(of: pendingRequest?.id) { _, newValue in
            // The cover's outer Binding tracking has been flaky on tvOS — call
            // dismiss() directly from inside the cover when AppState clears
            // the pending request (success path). This is the authoritative
            // signal that the PIN was accepted.
            if newValue == nil {
                PlozzLog.auth.debug("pendingPlexPINRequest cleared — calling dismiss()")
                dismiss()
            }
        }
    }

    /// Large circular Plex avatar with a small lock badge — matches Plex's
    /// tvOS PIN screen. Falls back to a person glyph when no thumb is cached.
    private var avatarBadge: some View {
        let url = avatarURLString.flatMap(URL.init(string:))
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.18))
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(Circle())

            // Small lock badge in the corner, à la Plex.
            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 2))
            .offset(x: 4, y: 4)
        }
    }

    /// Four large rounded boxes that fill as digits land. Each is dark/outline
    /// when empty and solid+dot when filled. The next-to-fill box gets a thin
    /// highlight so the user can see entry progress without any focus on the
    /// boxes themselves (the strip below owns focus).
    private var pinBoxes: some View {
        HStack(spacing: 18) {
            ForEach(0..<Self.pinLength, id: \.self) { idx in
                let filled = idx < pin.count
                let next = !filled && idx == pin.count
                ZStack {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .fill(filled ? Color.white.opacity(0.95) : Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .strokeBorder(
                            next ? Color.white.opacity(0.85) : Color.white.opacity(filled ? 0 : 0.25),
                            lineWidth: next ? 3 : 2
                        )
                    if filled {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 72, height: 84)
            }
        }
    }

    private func appendDigit(_ d: String) {
        guard !isSubmitting else { return }
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < Self.pinLength else { return }
        pin.append(d)
        if pin.count == Self.pinLength {
            // Auto-submit the moment the 4th digit lands. Snappy is the goal.
            // Flip isSubmitting so the user sees a spinner instead of "four
            // dots and nothing happens" while the network round-trip runs.
            PlozzLog.auth.debug("PIN auto-submit at 4 digits")
            isSubmitting = true
            onSubmit(pin)
        }
    }

    private func deleteDigit() {
        guard !isSubmitting else { return }
        if !pin.isEmpty { pin.removeLast() }
    }
}

/// Single horizontal row of digit keys 0–9 plus a delete key — the layout
/// Plex itself uses on tvOS, and the one-axis path the Siri remote handles
/// best. Each key is a focusable Button so focus is always anchored and
/// Menu/Back can't fall through to the system.
///
/// Compact, FIXED-size keys (no tile-to-fill). With 11 keys at 84pt + 10×16
/// spacing the strip is ~1080pt and centers naturally on a 1920pt tvOS
/// screen, leaving ~400pt clearance per side — zero clipping, and plenty
/// of room for the focused-key scale lift.
private struct PINStrip: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let digits: [String] = ["1","2","3","4","5","6","7","8","9","0"]
    private let digitKeyWidth: CGFloat = 84
    private let deleteKeyWidth: CGFloat = 104
    private let keyHeight: CGFloat = 100

    var body: some View {
        HStack(spacing: 16) {
            ForEach(digits, id: \.self) { d in
                Button {
                    onDigit(d)
                } label: {
                    Text(d)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                }
                .buttonStyle(PINKeyStyle(width: digitKeyWidth, height: keyHeight, isDestructive: false))
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 28, weight: .semibold))
            }
            .buttonStyle(PINKeyStyle(width: deleteKeyWidth, height: keyHeight, isDestructive: true))
            .accessibilityLabel("Delete")
        }
        // Vertical slack so the focus lift has clearance without bumping
        // neighbors in the column.
        .padding(.vertical, 12)
    }
}

/// Fixed-size, focus-friendly key button. Drawn entirely by this style so
/// the key's rendered frame is exactly width×height — no auto-expanding
/// fill from a bordered/prominent style and no inheritance from the parent
/// layout. Focused state lifts (scale 1.08) and brightens (white fill,
/// black foreground), with a soft drop shadow for depth.
private struct PINKeyStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(
            configuration: configuration,
            width: width,
            height: height,
            isDestructive: isDestructive
        )
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let width: CGFloat
    let height: CGFloat
    let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.18))
            )
            .foregroundStyle(
                isFocused
                ? (isDestructive ? Color.red : Color.black)
                : Color.primary
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.38 : 0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Brief splash while we check for a stored session.
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Plozz")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let message: String
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
