#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import FeatureProfiles
import FeatureSettings
import Foundation
import SwiftUI
import UIKit

public struct PlozziOSRootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// The reader's text size. Feeds `PlozzMetrics` so the shared type/geometry
    /// table rebuilds when it changes (see where the metrics are injected below).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency)
    private var systemReduceTransparency
    @State private var appModel = PlozziOSAppModel.shared
    @State private var sceneID = UUID()
    @State private var heroTrailerController = HeroTrailerController()
    @State private var sidebarGeometry = PlozziOSSidebarGeometryModel()
    @State private var showingAddServer = false
    @State private var addServerPresentationColorScheme: ColorScheme = .dark
    @State private var showingSettings = false
    /// Owned here rather than in the tab shell so `receivePairingURL` can see
    /// whether it is up before asking for another sheet.
    @State private var showingProfileSwitcher = false
    /// A pairing link that arrived while a sheet was open — see
    /// `receivePairingURL`.
    @State private var deferredPairingURL: URL?
    /// A synced server the user tapped "Set Up" on, used to pre-fill the Add Server
    /// sheet so they only have to sign in.
    @State private var serverSetupSeed: SyncedAccountDescriptor?
    /// Action chosen in the new-server prompt, run after the prompt sheet dismisses so
    /// we never stack two sheets in the same runloop.
    @State private var serverPromptFollowUp: ServerPromptFollowUp?
    /// Drives the "set up from another device" pairing flow launched from the prompt,
    /// carrying which server the user wants signed in (nil = not pairing).
    @State private var pairingServer: SyncedAccountDescriptor?
    /// Fresh-launch "we found your setup" full-page cover. Shown once per cold launch
    /// when there are servers that need bringing over (`pendingServersNeedingSetup`),
    /// regardless of whether accounts/profiles already exist — so the "open a device
    /// and finish bringing over your Apple TV's servers" case works even on the 100th
    /// open, not just a blank first run. Mid-session detections still use the smaller
    /// drawer (`pendingSyncedServerPrompt`), so we don't hijack active use.
    @State private var showDetectedCover = false
    /// Set true once we've decided about the detected cover for this launch (shown it,
    /// or the short cold-launch window elapsed), so it never re-pops mid-session.
    @State private var coldLaunchDetectionHandled = false
    /// Defer launching the receive/pairing flow until the detected cover has fully
    /// dismissed, so two full-screen covers never race in the same runloop.
    @State private var detectedFollowUpReceive = false
    /// Drives the unrestricted receive/pairing flow launched from the detected-setup
    /// page (brings the whole household over from the detected device).
    @State private var showReceiveFromDetected = false
    private var releaseNotes: ReleaseNotesModel { .shared }

    public init() {}

    public var body: some View {
        Group {
            if appModel.accounts.isEmpty {
                PlozziOSOnboardingView(appModel: appModel)
            } else if appModel.mustChooseProfile
                || (appModel.requiresLaunchProfileSelection
                    && !appModel.didCompleteLaunchProfileSelection) {
                PlozziOSProfilePickerView(
                    // Whoever watched on this device most recently leads.
                    profiles: appModel.profiles.profilesByRecency,
                    activeProfileID: appModel.profiles.activeProfileID,
                    onSelect: { profile in
                        // Completion is recorded by the model when the switch
                        // actually lands — a locked or PIN-gated profile only
                        // raises its prompt here, and cancelling it must leave
                        // the picker up rather than reveal the profile.
                        appModel.selectProfile(profile.id)
                    },
                    // Same abilities as the switcher. Withholding Add and Edit
                    // here made one screen behave as two: identical layout, but
                    // long-press did nothing and the Edit button was missing
                    // until you'd already picked someone. Netflix and the tvOS
                    // picker both manage profiles from the launch screen too.
                    manager: appModel.managementRequiresParentalPIN ? nil : appModel
                    // No `onCancel`: at launch there is nothing to go back to.
                )
            } else {
                PlozziOSTabShell(
                    appModel: appModel,
                    onAddServer: showAddServer,
                    showingSettings: $showingSettings,
                    showingProfileSwitcher: $showingProfileSwitcher,
                    deferredPairingURL: $deferredPairingURL,
                    systemColorScheme: systemColorScheme
                )
            }
        }
        .scrollContentBackground(.hidden)
        // One opaque cover for profile PIN then Plex PIN. Separate presentations
        // briefly exposed the tab shell between them.
        .fullScreenCover(isPresented: profileAccessGateBinding) {
            PlozziOSProfileAccessGateView(appModel: appModel)
        }
        // Setup that was abandoned part-way — quit mid-flow, or arrived over sync
        // from a device where it was never finished. The gate is persisted, so a
        // profile left behind it never imports a watchlist at all; resuming asks
        // the question that was never answered.
        //
        // Only the launch-origin case presents here. Creating a profile happens
        // inside the Settings sheet and is presented from there instead — a cover
        // asked for from this view while Settings is up would never appear. See
        // `ProfileOnboardingOrigin`.
        .fullScreenCover(isPresented: Binding(
            get: { appModel.isPresentingProfileOnboarding(from: .launch) },
            set: { if !$0 { appModel.cancelProfileOnboarding() } }
        )) {
            PlozziOSProfileOnboardingCover(appModel: appModel)
        }
        // "Who are you on this server?" for a question recorded while the user was
        // elsewhere — CloudSync enabling a server in the background, or an account
        // signing in and making an already-recorded question answerable.
        //
        // The Libraries screen presents this too, for questions raised by its own
        // toggle; that one is inside the Settings sheet and can't present when
        // Settings is closed, which is most of the time. Without a presenter here
        // the question would gate the watchlist import while nothing ever asked
        // it. The two are mutually exclusive on `isSettingsPresented` so they
        // can't both try.
        .sheet(item: Binding(
            get: { appModel.isSettingsPresented ? nil : appModel.pendingIdentityAccount },
            set: { if $0 == nil { appModel.resolveIdentityPromptForPending() } }
        )) { account in
            PlozziOSServerIdentityPromptView(
                appModel: appModel,
                account: account,
                onFinish: { appModel.concludeIdentityPrompt(for: account.id) },
                onDecline: { appModel.declineIdentityPrompt(for: account.id) }
            )
        }
        .task { appModel.resumeProfileOnboardingIfNeeded() }
        .onAppear { PlozziOSScreenshotSeed.applyIfRequested(to: appModel) }
        .task {
            // Detect on cold launch: fire immediately if the pending set is already
            // warm, and close the cold-launch window after a short grace period so a
            // later (mid-session) detection uses the drawer instead of this cover.
            considerColdLaunchDetection()
            try? await Task.sleep(for: .seconds(8))
            coldLaunchDetectionHandled = true
        }
        .onChange(of: appModel.pendingServersNeedingSetup.count) { _, _ in
            considerColdLaunchDetection()
        }
        .fullScreenCover(isPresented: $showDetectedCover, onDismiss: {
            if detectedFollowUpReceive {
                detectedFollowUpReceive = false
                showReceiveFromDetected = true
            }
        }) {
            PlozziOSDetectedSetupView(
                appModel: appModel,
                onSetUpFromDevice: {
                    detectedFollowUpReceive = true
                    showDetectedCover = false
                },
                onSetUpManually: { showDetectedCover = false }
            )
            .preferredColorScheme(resolvedPalette.isLight ? .light : .dark)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.setScene(sceneID, isActive: newPhase == .active)
            if newPhase == .active {
                appModel.accountsProviders.retryUnconfirmedCredentials()
                appModel.syncCloudOnForeground()
            }
        }
        .onDisappear {
            appModel.removeScene(sceneID)
        }
        .alert(
            syncSetupOfferTitle,
            isPresented: Binding(
                // Presentation is driven purely by pendingSyncSetupOffer; the two
                // buttons own confirm/decline, so the setter must NOT have a side
                // effect (that would double-fire and race the button action).
                get: { appModel.pendingSyncSetupOffer != nil },
                set: { _ in }
            ),
            presenting: appModel.pendingSyncSetupOffer
        ) { _ in
            Button("Set Up") { appModel.confirmSyncSetupOffer() }
            Button("Not Now", role: .cancel) { appModel.declineSyncSetupOffer() }
        } message: { _ in
            Text(syncSetupOfferServerName != nil
                 ? "Sign this device in to “\(syncSetupOfferServerName!)”."
                 : "Send your servers and sign-in so it’s ready to watch.")
        }
        .sheet(item: serverPromptBinding, onDismiss: consumeServerPromptFollowUp) { descriptor in
            PlozziOSNewServerPromptView(
                descriptor: descriptor,
                accent: resolvedPalette.accent,
                onSignIn: {
                    serverPromptFollowUp = .signIn(descriptor)
                    appModel.clearPendingSyncedServerPrompt()
                },
                onUseOtherDevice: {
                    serverPromptFollowUp = .pairDevice(descriptor)
                    appModel.clearPendingSyncedServerPrompt()
                },
                onNotNow: {
                    serverPromptFollowUp = nil
                    appModel.clearPendingSyncedServerPrompt()
                }
            )
            .preferredColorScheme(resolvedPalette.isLight ? .light : .dark)
        }
        .fullScreenCover(item: $pairingServer) { descriptor in
            PlozziOSSyncSetupReceiveView(appModel: appModel, requestedServer: descriptor) {
                pairingServer = nil
            }
            .preferredColorScheme(resolvedPalette.isLight ? .light : .dark)
        }
        .fullScreenCover(isPresented: $showReceiveFromDetected) {
            PlozziOSSyncSetupReceiveView(appModel: appModel) {
                showReceiveFromDetected = false
            }
            .preferredColorScheme(resolvedPalette.isLight ? .light : .dark)
        }
        .background { AppBackground(palette: resolvedPalette) }
        .environment(\.themePalette, resolvedPalette)
        // See the tvOS root: reading `dynamicTypeSize` is what rebuilds the metrics
        // when the reader's text size changes, rather than only on relaunch.
        .environment(
            \.plozzMetrics,
            PlozzMetrics.touch(
                density: appModel.settings.density.density,
                dynamicTypeSize: dynamicTypeSize
            )
        )
        .mediaItemActionHandler(appModel.mediaItemActionHandler)
        .environment(
            \.plozzCardStyle,
            appModel.settings.cardStyle.style
        )
        .environment(
            \.plozzWatchStatusIndicator,
            appModel.settings.watchIndicator.indicator
        )
        // See the note in RootView: drives whether an unowned title's corner mark
        // reads as information or as an invitation to request it.
        .environment(\.plozzSeerConnected, appModel.seerService.isConfigured)
        .environment(
            \.plozzReduceTransparency,
            appModel.settings.transparency.preference.reducesTransparency(
                systemReduceTransparency: systemReduceTransparency
            )
        )
        .environment(
            \.colorScheme,
            resolvedPalette.isLight ? .light : .dark
        )
        .transientStatusOverlay(
            presenter: appModel.transientStatusPresenter,
            bottomPadding: 72,
            isLightSurface: resolvedPalette.isLight
        )
        .environment(appModel)
        .environment(heroTrailerController)
        .environment(sidebarGeometry)
        .syncsWindowInterfaceStyle(isLight: resolvedPalette.isLight)
        .id(shellIdentity)
        .onChange(of: shellIdentity) {
            heroTrailerController.stop()
        }
        .sheet(
            isPresented: $showingAddServer,
            onDismiss: {
                serverSetupSeed = nil
                appModel.finishManagedServerPresentation()
                consumeDeferredPairingURL()
            }
        ) {
            AddServerView(
                appModel: appModel,
                initialProvider: serverSetupSeed?.provider ?? .jellyfin,
                initialAddress: serverSetupSeed?.candidateBaseURLs.first?.absoluteString ?? ""
            )
                .preferredColorScheme(addServerPresentationColorScheme)
                .presentationSizing(.page)
        }
        .sheet(
            item: plexUserSelectionBinding
        ) { selection in
            PlozziOSPlexUserSelectionView(
                selection: selection,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        .sheet(
            item: librarySelectionBinding
        ) { selection in
            PlozziOSLibrarySelectionView(
                accounts: appModel.accountsProviders.resolvedAccounts(
                    withIDs: selection.accountIDs
                ),
                visibility: appModel.settings.homeVisibility,
                onContinue: appModel.completeLibrarySelection
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        // Presented ONCE for the whole first-run flow, not per step. Keyed by
        // `item:` the cover tore down and rebuilt on every step change — because
        // FirstRunStep is its own Identifiable id — so the flow dismissed to
        // Home and re-presented between screens. Steps now cross-fade inside it.
        .fullScreenCover(isPresented: firstRunPresentedBinding) {
            PlozziOSFirstRunView(
                step: appModel.pendingFirstRunStep,
                appModel: appModel,
                systemColorScheme: systemColorScheme
            )
        }
        .task(id: releaseNotesStartupReady) {
            if releaseNotesStartupReady {
                releaseNotes.prepareForStartup()
            }
        }
        .sheet(
            isPresented: Binding(
                get: { releaseNotes.hasPendingStartupNotes },
                set: { presented in
                    if !presented {
                        releaseNotes.dismissStartupNotes()
                    }
                }
            ),
            onDismiss: { releaseNotes.dismissStartupNotes() }
        ) {
            ReleaseNotesStartupView(model: releaseNotes)
                .presentationSizing(.page)
        }
        .installNightShiftOverlay(appModel.settings.nightShift)
        .onOpenURL { url in
            receivePairingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                receivePairingURL(url)
            }
        }
        .sheet(item: pendingPairingBinding) { pairing in
            PlozziOSSyncSetupDeepLinkView(
                appModel: appModel,
                invite: pairing.invite,
                onClose: { appModel.pendingPairingInvite = nil }
            )
            .preferredColorScheme(resolvedPalette.isLight ? .light : .dark)
        }
    }

    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }

    private var releaseNotesStartupReady: Bool {
        !appModel.accounts.isEmpty
            && !appModel.mustChooseProfile
            && (!appModel.requiresLaunchProfileSelection
                || appModel.didCompleteLaunchProfileSelection)
            && appModel.pendingFirstRunStep == nil
            && !showDetectedCover
            && coldLaunchDetectionHandled
            && !showingSettings
            && !showingProfileSwitcher
            && !showingAddServer
            && pairingServer == nil
            && !showReceiveFromDetected
            && appModel.lockedSwitch == nil
            && appModel.parentalSwitch == nil
            && appModel.plexHomeUsers.pendingPlexPINRequest == nil
            && appModel.pendingIdentityAccount == nil
            && appModel.pendingLibrarySelection == nil
            && appModel.pendingSyncedServerPrompt == nil
            && appModel.pendingPairingInvite == nil
            && appModel.pendingSyncSetupOffer == nil
    }

    /// The name THIS device holds for the offer's requested account (a per-server
    /// offer is only surfaced when this device has the account), rather than trusting
    /// the rendezvous-supplied string.
    private var syncSetupOfferServerName: String? {
        guard let requested = appModel.pendingSyncSetupOffer?.requestedAccountID else { return nil }
        return appModel.accountsProviders.accounts.first(where: { $0.id == requested })?.server.name
    }

    /// Title for the same-Apple-ID setup offer alert. Names the specific server when
    /// the offering device asked for just one, else the device-level framing.
    private var syncSetupOfferTitle: LocalizedStringResource {
        let device = appModel.pendingSyncSetupOffer?.deviceName ?? "your device"
        if let server = syncSetupOfferServerName {
            return "Set up “\(server)” on “\(device)”?"
        }
        return "Set up “\(device)”?"
    }

    private var shellIdentity: String {
        if appModel.requiresLaunchProfileSelection
            && !appModel.didCompleteLaunchProfileSelection {
            return "profile-picker"
        }
        let profile = appModel.profiles.activeProfile
        return "\(profile.id)#"
            + profile.plexPlaybackIdentityKey(
                for: appModel.accountsProviders.homeAccounts.map(\.account)
            )
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: {
                // Suppressed during first run: the flow cover renders this step
                // inline, so presenting it here too would stack a sheet on the
                // cover (and reintroduce the dismiss-to-Home hand-off).
                showingSettings || appModel.pendingFirstRunStep != nil
                    ? nil
                    : appModel.plexHomeUsers.pendingPlexUserSelection
            },
            set: { selection in
                if selection == nil {
                    appModel.cancelPlexUserSelectionDuringOnboarding()
                }
            }
        )
    }

    private var profileAccessGateBinding: Binding<Bool> {
        Binding(
            get: {
                if appModel.lockedSwitch != nil { return true }
                if appModel.parentalSwitch != nil { return true }
                guard !showingSettings,
                      appModel.profileOnboardingStep != .libraries
                else { return false }
                return appModel.plexHomeUsers.pendingPlexPINRequest != nil
            },
            set: { presented in
                if !presented {
                    appModel.cancelProfileLockPrompt()
                    appModel.cancelParentalSwitch()
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: {
                // Same as the Plex-user step: inline during first run, its own
                // sheet when adding a server later.
                showingSettings || appModel.pendingFirstRunStep != nil
                    ? nil
                    : appModel.pendingLibrarySelection
            },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    /// True while ANY first-run step is pending. The specific step is read inside
    /// the cover so changing it animates in place instead of re-presenting.
    private var firstRunPresentedBinding: Binding<Bool> {
        Binding(
            get: { appModel.pendingFirstRunStep != nil },
            set: { _ in }
        )
    }

    /// Takes a pairing link, waiting for an open sheet to close first.
    ///
    /// A link can arrive while the app is already foreground with Settings or the
    /// profile picker up. The pairing sheet lives on the root, and one requested
    /// from under an open sheet is the arrangement SwiftUI drops — silently, and
    /// with `pendingPairingInvite` left set so it is never re-requested, which
    /// means the link simply does nothing until relaunch.
    private func receivePairingURL(_ url: URL) {
        guard showingSettings || showingProfileSwitcher || showingAddServer else {
            appModel.handleIncomingURL(url)
            return
        }
        deferredPairingURL = url
        showingSettings = false
        showingProfileSwitcher = false
        showingAddServer = false
    }

    /// Raises a link parked by `receivePairingURL` now that the sheet that was
    /// covering the root has actually gone.
    private func consumeDeferredPairingURL() {
        guard let url = deferredPairingURL else { return }
        deferredPairingURL = nil
        appModel.handleIncomingURL(url)
    }

    private var pendingPairingBinding: Binding<PendingPairing?> {
        Binding(
            get: { appModel.pendingPairingInvite.map(PendingPairing.init(invite:)) },
            set: { newValue in
                if newValue == nil { appModel.pendingPairingInvite = nil }
            }
        )
    }

    private func showAddServer() {
        addServerPresentationColorScheme = resolvedPalette.isLight ? .light : .dark
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    /// Adopt a server synced from another device: open the Add Server sheet pre-filled
    /// with its provider + address, so the user only has to sign in.
    private func setUpPendingSyncedServer(_ descriptor: SyncedAccountDescriptor) {
        serverSetupSeed = descriptor
        showAddServer()
    }

    /// Presentation binding for the one-time new-server prompt. Clearing it (a button
    /// tap or a swipe-down) dismisses the sheet.
    private var serverPromptBinding: Binding<SyncedAccountDescriptor?> {
        Binding(
            // Suppress the mid-session drawer while the full-page "we found your setup"
            // cover is (or is about to be) presented at cold launch, so the two don't
            // fight over the same server.
            get: { (showDetectedCover || detectedFollowUpReceive) ? nil : appModel.pendingSyncedServerPrompt },
            set: { if $0 == nil { appModel.clearPendingSyncedServerPrompt() } }
        )
    }

    private func considerColdLaunchDetection() {
        guard !coldLaunchDetectionHandled else { return }
        guard !appModel.pendingServersNeedingSetup.isEmpty else { return }
        coldLaunchDetectionHandled = true
        // The cover supersedes the drawer for these servers this launch.
        appModel.clearPendingSyncedServerPrompt()
        showDetectedCover = true
    }

    /// Run the action chosen in the prompt once its sheet has fully dismissed. A
    /// swipe-to-dismiss leaves `serverPromptFollowUp == nil`, which behaves like
    /// "Not Now" (the server still lives under Settings ▸ iCloud Sync).
    private func consumeServerPromptFollowUp() {
        guard let follow = serverPromptFollowUp else { return }
        serverPromptFollowUp = nil
        switch follow {
        case .signIn(let descriptor):
            setUpPendingSyncedServer(descriptor)
        case .pairDevice(let descriptor):
            pairingServer = descriptor
        }
    }
}

private struct PendingPairing: Identifiable {
    let invite: String
    var id: String { invite }
}

/// The action a user chose in the new-server prompt, deferred until the prompt sheet
/// dismisses so a follow-up sheet never races the dismissal.
private enum ServerPromptFollowUp {
    case signIn(SyncedAccountDescriptor)
    case pairDevice(SyncedAccountDescriptor)
}

private enum PlozziOSDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case watchlist
    case downloads
    case search

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .watchlist: "Watchlist"
        case .downloads: "Downloads"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .watchlist: "bookmark"
        case .downloads: "arrow.down.circle"
        case .search: "magnifyingglass"
        }
    }
}

/// Performs the capture rig's tab requests. See ``PlozziOSScreenshotDirector``.
private struct PlozziOSScreenshotTabRouter: View {
    let director: PlozziOSScreenshotDirector
    let onSelect: (String) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: director.tab) {
                guard let tab = director.tab else { return }
                director.tab = nil
                onSelect(tab)
                director.finish(.ok)
            }
    }
}

private struct PlozziOSTabShell: View {
    @Environment(\.themePalette) private var palette
    @Environment(PlozziOSSidebarGeometryModel.self)
    private var sidebarGeometry
    @State private var settingsPresentationColorScheme: ColorScheme = .dark
    @State private var selectedDestination: PlozziOSDestination = .home
    @State private var sharedHomeViewModel: HomeViewModel
    /// The profile picker opened deliberately (from Settings) rather than at
    /// launch. Presented from the ROOT so the Parental PIN and profile-lock gates
    /// it can raise aren't asked for from underneath the Settings sheet — the
    /// arrangement that fails silently.
    /// Set while Settings is closing, so the picker can be raised from its
    /// `onDismiss` rather than in the same turn as the dismissal.
    @State private var wantsProfileSwitcher = false
    /// A profile chosen in the picker, switched to once the picker has gone: the
    /// parental/lock gates are covers on an ANCESTOR, and asking for those while
    /// this cover is dismissing is the same contested-slot case.
    @State private var pendingSwitchProfileID: String?

    /// Raises a link parked by `PlozziOSRootView.receivePairingURL` now that the
    /// sheet that was covering the root has actually gone.
    private func consumeDeferredPairingURL() {
        guard let url = deferredPairingURL else { return }
        deferredPairingURL = nil
        appModel.handleIncomingURL(url)
    }
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @Binding var showingSettings: Bool
    @Binding var showingProfileSwitcher: Bool
    /// A pairing link parked until this shell's sheets have closed — see
    /// `PlozziOSRootView.receivePairingURL`.
    @Binding var deferredPairingURL: URL?
    let systemColorScheme: ColorScheme

    init(
        appModel: PlozziOSAppModel,
        onAddServer: @escaping () -> Void,
        showingSettings: Binding<Bool>,
        showingProfileSwitcher: Binding<Bool>,
        deferredPairingURL: Binding<URL?>,
        systemColorScheme: ColorScheme
    ) {
        self.appModel = appModel
        self.onAddServer = onAddServer
        _showingSettings = showingSettings
        _showingProfileSwitcher = showingProfileSwitcher
        _deferredPairingURL = deferredPairingURL
        self.systemColorScheme = systemColorScheme
        _sharedHomeViewModel = State(
            initialValue: Self.makeHomeViewModel(appModel: appModel)
        )
    }

    private static func makeHomeViewModel(
        appModel: PlozziOSAppModel
    ) -> HomeViewModel {
        HomeViewModel(
            accounts: appModel.accountsProviders.homeAccounts,
            contentStore: HomeContentStore(
                namespace: appModel.profiles.activeNamespace
            ),
            identitySources: appModel.identityIndex.identitySourcesProvider,
            currentVisibility: { [weak appModel] in
                appModel?.settings.homeVisibility.visibility ?? .default
            },
            pendingWatchMutations: { [weak appModel] in
                await appModel?.pendingWatchMutations() ?? []
            },
            recentlyAppliedRecency: { [weak appModel] in
                await appModel?.appliedWatchRecency() ?? [:]
            },
            mediaItemActionHandler: appModel.mediaItemActionHandler
        )
    }

    var body: some View {
        TabView(selection: $selectedDestination) {
            Tab(
                "Home",
                systemImage: "house",
                value: PlozziOSDestination.home
            ) {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .home,
                        appModel: appModel,
                        sharedHomeViewModel: sharedHomeViewModel,
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                    .plozziOSLibraryDestination(appModel: appModel)
                    .plozziOSItemNavigation(appModel: appModel, registersScreenshotRouting: true)
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .tabBar)
                .background { AppBackground(palette: palette) }
            }

            if appModel.settings.navigation.showsWatchlist {
                Tab(
                    "Watchlist",
                    systemImage: "bookmark",
                    value: PlozziOSDestination.watchlist
                ) {
                    NavigationStack {
                        PlozziOSDestinationView(
                            destination: .watchlist,
                            appModel: appModel,
                            sharedHomeViewModel: sharedHomeViewModel,
                            onAddServer: onAddServer,
                            onShowSettings: showSettings
                        )
                        .plozziOSItemNavigation(appModel: appModel)
                    }
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .background { AppBackground(palette: palette) }
                }
            }

            Tab(value: PlozziOSDestination.downloads) {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .downloads,
                        appModel: appModel,
                        sharedHomeViewModel: sharedHomeViewModel,
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .background { AppBackground(palette: palette) }
            } label: {
                Label {
                    Text("Downloads")
                } icon: {
                    downloadsTabIcon
                }
            }

            // Last, and with the SEARCH ROLE rather than an ordinary tab: on a
            // wide layout with the top tab bar (iPad) the system pulls a
            // search-role tab out of the row and renders it as a lone
            // magnifying glass at the trailing edge, which is the icon-only
            // treatment we want — and it stays a normal labelled tab on iPhone.
            // Doing that by hand would mean blanking the title, which reads as a
            // bug to VoiceOver.
            Tab(
                "Search",
                systemImage: "magnifyingglass",
                value: PlozziOSDestination.search,
                role: .search
            ) {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .search,
                        appModel: appModel,
                        sharedHomeViewModel: sharedHomeViewModel,
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                    .plozziOSItemNavigation(appModel: appModel)
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .background { AppBackground(palette: palette) }
            }
        }

        .tabViewStyle(.tabBarOnly)
        .onChange(of: appModel.settings.navigation.showsWatchlist) {
            _, showsWatchlist in
            selectedDestination = WatchlistNavigationPolicy.resolvedSelection(
                selectedDestination,
                watchlist: .watchlist,
                home: .home,
                showsWatchlist: showsWatchlist
            )
        }
        .onChange(of: homeContentIdentity) {
            _, _ in
            sharedHomeViewModel = Self.makeHomeViewModel(appModel: appModel)
        }
        .background { AppBackground(palette: palette) }
        .background(alignment: .topLeading) {
            PlozziOSHomeSidebarOverlapProbe(
                enabled: selectedDestination == .home,
                geometryModel: sidebarGeometry
            )
            .frame(width: 0, height: 0)
        }
        .background {
            // Switching tabs is the shell's job, so the capture rig's tab requests
            // are consumed here rather than in the Home stack. A zero-size leaf, so
            // reading the request never invalidates the tab view.
            PlozziOSScreenshotTabRouter(
                director: appModel.screenshotDirector,
                onSelect: { name in
                    guard let destination = PlozziOSDestination(rawValue: name) else { return }
                    selectedDestination = WatchlistNavigationPolicy.resolvedSelection(
                        destination,
                        watchlist: .watchlist,
                        home: .home,
                        showsWatchlist: appModel.settings.navigation.showsWatchlist
                    )
                }
            )
            #if DEBUG
            // The push seams live on the Home stack, so the router brings this tab
            // forward before it navigates. Registered here because only the shell
            // owns the tab selection.
            .onAppear { appModel.screenshotDirector.selectHomeTab = { selectedDestination = .home } }
            #endif
        }
        .background {
            // Every other request — detail, person, library, play — is performed
            // here too, OUTSIDE the navigation stacks. On the Home screen the
            // router's `.task` was cancelled the moment a pushed page covered it,
            // so only the first request of a run was ever acked; out here nothing
            // covers it, and it reaches the pushes and player through the seams the
            // Home stack and Home view register on the director.
            PlozziOSScreenshotRouter(appModel: appModel)
        }
        // The setup cover is presented from inside Settings when Settings is up,
        // and from the root when it isn't — see `ProfileOnboardingOrigin`. That
        // decision reads this.
        .onChange(of: showingSettings) { _, presented in
            // Only the RISING edge here. Dismissal is animated, and publishing
            // false the moment Close is tapped lets the root ask for the identity
            // sheet while Settings is still covering it — SwiftUI drops that, and
            // nothing re-triggers it. The falling edge is `onDismiss`, which runs
            // when the sheet is actually gone.
            if presented { appModel.noteSettingsPresented(true) }
        }
        .fullScreenCover(isPresented: $showingProfileSwitcher, onDismiss: {
            // The gates `selectProfile` can raise are covers on the ROOT. Asking
            // for one while this cover is still dismissing can be dropped, and
            // because the gate's binding stays true SwiftUI never re-requests it —
            // profile switching would wedge until relaunch.
            if let id = pendingSwitchProfileID {
                pendingSwitchProfileID = nil
                appModel.selectProfile(id)
            }
            consumeDeferredPairingURL()
        }) {
            PlozziOSProfilePickerView(
                profiles: appModel.profiles.profilesByRecency,
                activeProfileID: appModel.profiles.activeProfileID,
                onSelect: { profile in
                    pendingSwitchProfileID = profile.id
                    showingProfileSwitcher = false
                },
                // Withheld inside an enforced Kids Profile — creating a profile
                // switches into it, which would bypass the Parental PIN gate.
                manager: appModel.managementRequiresParentalPIN ? nil : appModel,
                onCancel: { showingProfileSwitcher = false }
            )
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            appModel.noteSettingsPresented(false)
            if wantsProfileSwitcher {
                wantsProfileSwitcher = false
                showingProfileSwitcher = true
            } else if let id = pendingSwitchProfileID {
                // Same rule as the picker's `onDismiss`: the gates this can
                // raise are covers on the ROOT, so the switch waits until
                // Settings is actually gone.
                pendingSwitchProfileID = nil
                appModel.selectProfile(id)
            }
            consumeDeferredPairingURL()
        }) {
            PlozziOSSettingsView(
                appModel: appModel,
                onClose: { showingSettings = false },
                onSwitchProfile: {
                    // Requested, not presented here. Dismissing Settings and
                    // presenting the picker in the SAME turn is the arrangement
                    // SwiftUI drops — and this is the only way to switch profiles
                    // on iOS, so losing it strands the user. The sheet's
                    // `onDismiss` raises the picker once Settings is actually gone.
                    wantsProfileSwitcher = true
                    showingSettings = false
                },
                onSwitchTo: { pendingSwitchProfileID = $0 },
                systemColorScheme: systemColorScheme
            )
            .preferredColorScheme(settingsPresentationColorScheme)
            .presentationSizing(.page)
            // Elevation edge for the all-black theme: without it the sheet's
            // dark surface blends straight into the dark page behind it, so the
            // drawer doesn't read as a layer above the content. Reuse the exact
            // hairline the settings group cards use (`cardOpaqueBorder`), pin the
            // sheet corner radius so the stroke traces the card's rounded top
            // corners precisely, and mask it to the top so only the floating top
            // rim shows — the sides/bottom sit at the screen edge where a border
            // adds nothing. Dark themes only; a light sheet already separates
            // itself from the page behind it.
            .presentationCornerRadius(Self.settingsSheetCornerRadius)
            .overlay {
                if !settingsPalette.isLight {
                    RoundedRectangle(
                        cornerRadius: Self.settingsSheetCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(settingsPalette.overlay.border ?? .clear, lineWidth: settingsPalette.overlay.borderWidth)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.04),
                                .init(color: .clear, location: 0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Corner radius pinned on the Settings sheet so the elevation border can
    /// trace the card's rounded edge exactly (SwiftUI's default sheet radius is
    /// unspecified, which would leave the overlay stroke and the real corner
    /// slightly misaligned).
    private static let settingsSheetCornerRadius: CGFloat = 20

    private var settingsPalette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }

    /// The retained Home model is profile/account scoped. Watchlist shares it
    /// within that scope, then a real profile or credential change replaces it.
    private var homeContentIdentity: String {
        let credentials = appModel.accounts
            .map { "\($0.id):\($0.credentialRevision)" }
            .joined(separator: "|")
        let active = appModel.accountsProviders.activeAccountIDs
            .sorted()
            .joined(separator: ",")
        return "\(appModel.profiles.activeProfileID)#\(credentials)#\(active)"
    }

    /// Overall progress for work that is actively transferring. Completed
    /// siblings in the same season batch remain in the denominator so the tab
    /// ring advances monotonically instead of resetting each time an episode
    /// finishes and the next queued episode starts.
    private var downloadsNavigationProgress: Double? {
        let active = appModel.downloads.records.filter {
            $0.status == .queued
                || $0.status == .preparing
                || $0.status == .downloading
        }
        guard !active.isEmpty else { return nil }

        let activeKeys = Set(active.map(\.identityKey))
        let activeBatchIDs = Set(active.compactMap(\.batchID))
        let tracked = appModel.downloads.records.filter {
            activeKeys.contains($0.identityKey)
                || $0.batchID.map(activeBatchIDs.contains) == true
        }

        // Keep one aggregation strategy for the lifetime of the cohort. Total
        // byte counts arrive only after each transfer starts; switching from
        // item-average to byte-weighted progress at that point makes the ring
        // visibly jump backward.
        let progress = tracked.reduce(0.0) {
            $0 + ($1.fractionCompleted
                ?? ($1.status == .completed ? 1 : 0))
        } / Double(tracked.count)
        return min(max(progress, 0), 1)
    }

    private var downloadsTabIcon: Image {
        guard let progress = downloadsNavigationProgress else {
            return Image(systemName: "arrow.down.circle")
        }
        return Image(uiImage: Self.downloadsProgressImage(progress: progress))
    }

    private static func downloadsProgressImage(progress: Double) -> UIImage {
        let size = CGSize(width: 21, height: 21)
        let lineWidth = 2.5
        let inset = lineWidth / 2
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            UIColor.black.withAlphaComponent(0.25).setStroke()
            let track = UIBezierPath(ovalIn: bounds)
            track.lineWidth = lineWidth
            track.stroke()

            UIColor.black.setStroke()
            let ring = UIBezierPath(
                arcCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                radius: (size.width - lineWidth) / 2,
                startAngle: -.pi / 2,
                endAngle: (-.pi / 2) + (2 * .pi * max(progress, 0.02)),
                clockwise: true
            )
            ring.lineWidth = lineWidth
            ring.lineCapStyle = .round
            ring.stroke()
        }
        .withRenderingMode(.alwaysTemplate)
    }

    private func showSettings() {
        settingsPresentationColorScheme = settingsPalette.isLight ? .light : .dark
        showingSettings = true
    }

}

private struct PlozziOSDestinationView: View {
    @Environment(\.themePalette) private var palette
    let destination: PlozziOSDestination
    let appModel: PlozziOSAppModel
    let sharedHomeViewModel: HomeViewModel
    let onAddServer: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            destinationContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .home:
            PlozziOSHomeLandingView(
                appModel: appModel,
                viewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
            .id(activeAccountsIdentity)
        case .watchlist:
            PlozziOSWatchlistLandingView(
                appModel: appModel,
                viewModel: sharedHomeViewModel,
                onShowSettings: onShowSettings
            )
        case .search:
            PlozziOSSearchView(
                appModel: appModel,
                onShowSettings: onShowSettings
            )
                .id(activeAccountsIdentity)
        case .downloads:
            PlozziOSDownloadsView(
                model: appModel.downloads,
                appModel: appModel,
                onShowSettings: onShowSettings
            )
                .id(appModel.profiles.activeProfileID)
        }
    }

    private var activeAccountsIdentity: String {
        let credentials = appModel.accounts
            .map { "\($0.id):\($0.credentialRevision)" }
            .joined(separator: "|")
        let active = appModel.accountsProviders.activeAccountIDs
            .sorted()
            .joined(separator: ",")
        return "\(credentials)#\(active)"
    }
}

private struct PlozziOSWatchlistLandingView: View {
    @Environment(\.mediaItemNavigator) private var navigateToItem
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let appModel: PlozziOSAppModel
    let viewModel: HomeViewModel
    let onShowSettings: () -> Void
    @State private var watchlistIntentRevision = 0

    var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your Watchlist is empty.",
            onRetry: { Task { await viewModel.load() } },
            loadingContent: {
                watchlistContent(
                    [],
                    loadingPlaceholderCount:
                        horizontalSizeClass == .regular ? 12 : 6
                )
            }
        ) { content in
            watchlistContent(
                content.watchlist,
                loadingPlaceholderCount:
                    viewModel.watchlistLoadingPlaceholderCount
            )
        }
        .task(
            id: PlozziOSHomeLoadID(
                visibility: appModel.settings.homeVisibility.visibility,
                viewModel: viewModel
            )
        ) {
            await viewModel.loadIfNeeded(
                for: appModel.settings.homeVisibility.visibility
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistDidChange
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistCacheDidLoad
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistLoadingProgressDidChange
            )
        ) { _ in
            viewModel.refreshWatchlistLoadingProgress()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .watchlistIntentDidChange
            )
        ) { _ in
            watchlistIntentRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaItemDidMutate)
        ) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PlozziOSSettingsAvatarButton(action: onShowSettings)
            }
        }
    }

    @ViewBuilder
    private func watchlistContent(
        _ items: [MediaItem],
        loadingPlaceholderCount: Int
    ) -> some View {
        if items.isEmpty, loadingPlaceholderCount == 0 {
            ContentUnavailableView {
                Label("Your Watchlist is empty", systemImage: "bookmark")
            } description: {
                Text("Add a movie or show from Plozz or any connected Watchlist.")
            }
        } else {
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: appModel.settings.density.density
                        .iOSPosterGridColumns(
                            horizontalSizeClass: horizontalSizeClass
                        ),
                    spacing: 18
                ) {
                    ForEach(MediaRowView.presentationElements(
                        items: items,
                        loadingPlaceholderCount: loadingPlaceholderCount
                    )) { element in
                        switch element {
                        case .item(let item):
                            Button {
                                navigateToItem?(item)
                            } label: {
                                PlozziOSPosterCard(
                                    item: item,
                                    spoilerSettings:
                                        appModel.settings.spoilers.settings,
                                    isPendingRemoval: isPendingRemoval(item)
                                )
                            }
                            .buttonStyle(.plain)
                        case .loadingPlaceholder:
                            PlozziOSPosterCard(
                                item: nil,
                                spoilerSettings:
                                    appModel.settings.spoilers.settings
                            )
                        }
                    }
                }
                .padding()
            }
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y
            } action: { oldOffset, newOffset in
                guard oldOffset != newOffset else { return }
                viewModel.noteHomeNavigationInteraction()
            }
        }
    }

    private func isPendingRemoval(_ item: MediaItem) -> Bool {
        _ = watchlistIntentRevision
        return appModel.mediaItemActionHandler
            .isActivelyRemovingFromWatchlist(item)
    }
}

private struct PlozziOSHomeLandingView: View {
    let appModel: PlozziOSAppModel
    let viewModel: HomeViewModel
    let onAddServer: () -> Void
    let onShowSettings: () -> Void
    @State private var showingReceive = false

    var body: some View {
        if appModel.accounts.isEmpty {
            ContentUnavailableView {
                Label("Build your library", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Connect a media server or an NFS network share to start watching.")
            } actions: {
                Button("Add Server", action: onAddServer)
                    .buttonStyle(.borderedProminent)
                Button("Set Up from Another Device") { showingReceive = true }
                NavigationLink("Add Network Share") {
                    PlozziOSAddShareView(appModel: appModel)
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PlozziOSSettingsAvatarButton(action: onShowSettings)
                }
            }
            .fullScreenCover(isPresented: $showingReceive) {
                PlozziOSSyncSetupReceiveView(appModel: appModel) { showingReceive = false }
            }
        } else {
            PlozziOSHomeView(
                appModel: appModel,
                viewModel: viewModel,
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
        }
    }
}

/// iPhone/iPad counterpart of tvOS's persistent profile-entry gate.
private struct PlozziOSProfileAccessGateView: View {
    let appModel: PlozziOSAppModel

    @Environment(\.themePalette) private var palette
    @State private var expectsTwoPINs: Bool

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        let profile = appModel.lockedSwitch?.target
        _expectsTwoPINs = State(initialValue:
            profile?.isLocked == true
                && profile?.lock?.matchesPlexPIN != true
                && profile?.playsAsPINProtectedPlexUser == true
        )
    }

    var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()

            if let request = appModel.parentalSwitch {
                // First: may you leave the child's profile at all?
                ParentalPINView(
                    destination: request.target,
                    errorMessage: request.error,
                    onSubmit: { appModel.submitParentalPIN($0) },
                    onCancel: { appModel.cancelParentalSwitch() }
                )
                .id("parental-pin")
                .transition(.opacity)
            } else if let lockRequest = appModel.lockedSwitch {
                ProfileLockPINView(
                    profile: lockRequest.target,
                    errorMessage: lockRequest.error,
                    isSyncEnabled: SyncSetupFeatureFlag().isEnabled,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 1, total: 2)
                        : nil,
                    onSubmit: { appModel.submitProfileLockPIN($0) },
                    onCancel: { appModel.cancelProfileLockPrompt() }
                )
                .id("profile-pin")
                .transition(.opacity)
            } else if let request = appModel.plexHomeUsers.pendingPlexPINRequest {
                PlozziOSPlexPINView(
                    model: appModel.plexHomeUsers,
                    request: request,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 2, total: 2)
                        : nil,
                    dismissOnSuccess: false
                )
                .id("plex-pin")
                .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: 0.2),
            value: appModel.lockedSwitch?.target.id
        )
    }
}
#endif
