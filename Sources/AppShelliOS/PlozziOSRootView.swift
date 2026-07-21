#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency)
    private var systemReduceTransparency
    @State private var appModel = PlozziOSAppModel()
    @State private var heroTrailerController = HeroTrailerController()
    @State private var sidebarGeometry = PlozziOSSidebarGeometryModel()
    @State private var showingAddServer = false
    @State private var addServerPresentationColorScheme: ColorScheme = .dark
    @State private var showingSettings = false
    @State private var completedLaunchProfileSelection = false

    public init() {}

    public var body: some View {
        Group {
            if appModel.requiresLaunchProfileSelection
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
            onDismiss: appModel.finishManagedServerPresentation
        ) {
            AddServerView(appModel: appModel)
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
}

private struct PendingPairing: Identifiable {
    let invite: String
    var id: String { invite }
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

    var body: some View {
        if appModel.accounts.isEmpty {
            ContentUnavailableView {
                Label("Build your library", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Connect a media server or an NFS network share to start watching.")
            } actions: {
                Button("Add Server", action: onAddServer)
                    .buttonStyle(.borderedProminent)
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
