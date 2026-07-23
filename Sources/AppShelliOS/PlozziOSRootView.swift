#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import Foundation
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency)
    private var systemReduceTransparency
    @State private var appModel = PlozziOSAppModel()
    @State private var heroTrailerController = HeroTrailerController()
    @State private var sidebarGeometry = PlozziOSSidebarGeometryModel()
    @State private var showingAddServer = false
    @State private var addServerPresentationColorScheme: ColorScheme = .dark
    @State private var showingSettings = false
    @State private var completedLaunchProfileSelection = false
    /// A synced server the user tapped "Set Up" on, used to pre-fill the Add Server
    /// sheet so they only have to sign in.
    @State private var serverSetupSeed: SyncedAccountDescriptor?
    /// Action chosen in the new-server prompt, run after the prompt sheet dismisses so
    /// we never stack two sheets in the same runloop.
    @State private var serverPromptFollowUp: ServerPromptFollowUp?
    /// Drives the "set up from another device" pairing flow launched from the prompt,
    /// carrying which server the user wants signed in (nil = not pairing).
    @State private var pairingServer: SyncedAccountDescriptor?
    /// Fresh-launch "we found your setup" page: the user tapped "Set up manually", so
    /// fall through to the normal chooser for the rest of this launch. Resets on the
    /// next cold launch (State is recreated), so a genuinely new detection can resurface.
    @State private var dismissedDetectedSetup = false
    /// Drives the unrestricted receive/pairing flow launched from the detected-setup
    /// page (brings the whole household over from the detected device).
    @State private var showReceiveFromDetected = false

    public init() {}

    public var body: some View {
        Group {
            if appModel.accounts.isEmpty {
                if !dismissedDetectedSetup && !appModel.pendingServersNeedingSetup.isEmpty {
                    // Fresh launch and we detected household servers that can't silently
                    // auto-connect (in practice the Apple TV's) — lead with them.
                    PlozziOSDetectedSetupView(
                        appModel: appModel,
                        onSetUpFromDevice: { showReceiveFromDetected = true },
                        onSetUpManually: { dismissedDetectedSetup = true }
                    )
                } else {
                    PlozziOSOnboardingView(appModel: appModel)
                }
            } else if appModel.requiresLaunchProfileSelection
                && !completedLaunchProfileSelection {
                PlozziOSProfilePickerView(
                    profiles: appModel.profiles.profiles,
                    activeProfileID: appModel.profiles.activeProfileID,
                    onSelect: { profile in
                        appModel.selectProfile(profile.id)
                        completedLaunchProfileSelection = true
                    }
                )
            } else {
                PlozziOSTabShell(
                    appModel: appModel,
                    onAddServer: showAddServer,
                    showingSettings: $showingSettings,
                    systemColorScheme: systemColorScheme
                )
            }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { appModel.syncCloudOnForeground() }
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
        .environment(
            \.plozzMetrics,
            PlozzMetrics.touch(density: appModel.settings.density.density)
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
        .environment(appModel)
        .environment(heroTrailerController)
        .environment(sidebarGeometry)
        .id(shellIdentity)
        .onChange(of: shellIdentity) {
            heroTrailerController.stop()
        }
        .sheet(
            isPresented: $showingAddServer,
            onDismiss: {
                serverSetupSeed = nil
                appModel.finishManagedServerPresentation()
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
            item: plexPINBinding
        ) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
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
        .fullScreenCover(
            item: firstRunStepBinding
        ) { step in
            PlozziOSFirstRunView(
                step: step,
                appModel: appModel,
                systemColorScheme: systemColorScheme
            )
        }
        .installNightShiftOverlay(appModel.settings.nightShift)
        .onOpenURL { url in
            appModel.handleIncomingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                appModel.handleIncomingURL(url)
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

    /// The name THIS device holds for the offer's requested account (a per-server
    /// offer is only surfaced when this device has the account), rather than trusting
    /// the rendezvous-supplied string.
    private var syncSetupOfferServerName: String? {
        guard let requested = appModel.pendingSyncSetupOffer?.requestedAccountID else { return nil }
        return appModel.accountsProviders.accounts.first(where: { $0.id == requested })?.server.name
    }

    /// Title for the same-Apple-ID setup offer alert. Names the specific server when
    /// the offering device asked for just one, else the device-level framing.
    private var syncSetupOfferTitle: String {
        let device = appModel.pendingSyncSetupOffer?.deviceName ?? "your device"
        if let server = syncSetupOfferServerName {
            return "Set up “\(server)” on “\(device)”?"
        }
        return "Set up “\(device)”?"
    }

    private var shellIdentity: String {
        if appModel.requiresLaunchProfileSelection
            && !completedLaunchProfileSelection {
            return "profile-picker"
        }
        return "\(appModel.profiles.activeProfileID)#"
            + "\(appModel.plexHomeUsers.plexIdentityGeneration)"
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: {
                showingSettings
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

    private var plexPINBinding:
        Binding<PlexHomeUsersModel.PlexPINRequest?>
    {
        Binding(
            get: {
                showingSettings
                    ? nil
                    : appModel.plexHomeUsers.pendingPlexPINRequest
            },
            set: { request in
                if request == nil {
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: { showingSettings ? nil : appModel.pendingLibrarySelection },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    private var firstRunStepBinding:
        Binding<PlozziOSAppModel.FirstRunStep?>
    {
        Binding(
            get: { appModel.pendingFirstRunStep },
            set: { _ in }
        )
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
            get: { appModel.pendingSyncedServerPrompt },
            set: { if $0 == nil { appModel.clearPendingSyncedServerPrompt() } }
        )
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
    case search
    case downloads

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .downloads: "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        }
    }
}

private struct PlozziOSTabShell: View {
    @Environment(\.themePalette) private var palette
    @Environment(PlozziOSSidebarGeometryModel.self)
    private var sidebarGeometry
    @State private var settingsPresentationColorScheme: ColorScheme = .dark
    @State private var selectedDestination: PlozziOSDestination = .home
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @Binding var showingSettings: Bool
    let systemColorScheme: ColorScheme

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
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .tabBar)
                .background { AppBackground(palette: palette) }
            }

            Tab(
                "Search",
                systemImage: "magnifyingglass",
                value: PlozziOSDestination.search
            ) {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .search,
                        appModel: appModel,
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .background { AppBackground(palette: palette) }
            }

            Tab(
                "Downloads",
                systemImage: "arrow.down.circle",
                value: PlozziOSDestination.downloads
            ) {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .downloads,
                        appModel: appModel,
                        onAddServer: onAddServer,
                        onShowSettings: showSettings
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .background { AppBackground(palette: palette) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background { AppBackground(palette: palette) }
        .background(alignment: .topLeading) {
            PlozziOSHomeSidebarOverlapProbe(
                enabled: selectedDestination == .home,
                geometryModel: sidebarGeometry
            )
            .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showingSettings) {
            PlozziOSSettingsView(
                appModel: appModel,
                onClose: { showingSettings = false },
                systemColorScheme: systemColorScheme
            )
            .preferredColorScheme(settingsPresentationColorScheme)
            .presentationSizing(.page)
        }
    }

    private var settingsPalette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
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
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
            .id(activeAccountsIdentity)
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

private struct PlozziOSHomeLandingView: View {
    let appModel: PlozziOSAppModel
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
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
        }
    }
}

#endif
