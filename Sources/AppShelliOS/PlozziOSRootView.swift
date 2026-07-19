#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var appModel = PlozziOSAppModel()
    @State private var selection: PlozziOSDestination? = .home
    @State private var showingAddServer = false
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
            } else if horizontalSizeClass == .regular {
                PlozziOSSplitShell(
                    selection: $selection,
                    appModel: appModel,
                    onAddServer: showAddServer
                )
            } else {
                PlozziOSTabShell(
                    appModel: appModel,
                    onAddServer: showAddServer
                )
            }
        }
        .background { AppBackground(palette: resolvedPalette) }
        .environment(\.themePalette, resolvedPalette)
        .environment(
            \.colorScheme,
            resolvedPalette.isLight ? .light : .dark
        )
        .environment(appModel)
        .id(shellIdentity)
        .sheet(
            isPresented: $showingAddServer,
            onDismiss: appModel.finishManagedServerPresentation
        ) {
            AddServerView(appModel: appModel)
        }
        .sheet(
            item: plexUserSelectionBinding
        ) { selection in
            PlozziOSPlexUserSelectionView(
                selection: selection,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
        }
        .sheet(
            item: plexPINBinding
        ) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
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
        }
        .fullScreenCover(
            item: firstRunStepBinding
        ) { step in
            PlozziOSFirstRunView(step: step, appModel: appModel)
        }
        .installNightShiftOverlay(appModel.settings.nightShift)
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
            get: { appModel.plexHomeUsers.pendingPlexUserSelection },
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
            get: { appModel.plexHomeUsers.pendingPlexPINRequest },
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
            get: { appModel.pendingLibrarySelection },
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

    private func showAddServer() {
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }
}

private enum PlozziOSDestination: String, CaseIterable, Identifiable {
    case home
    case search
    case downloads
    case settings

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .settings: "gear"
        }
    }
}

private struct PlozziOSSplitShell: View {
    @Binding var selection: PlozziOSDestination?
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        let destination = selection ?? .home

        NavigationSplitView {
            List(PlozziOSDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
            }
            .navigationTitle("Plozz")
        } detail: {
            NavigationStack(path: path(for: destination)) {
                PlozziOSDestinationView(
                    destination: destination,
                    appModel: appModel,
                    onAddServer: onAddServer
                )
            }
            .id(destination)
        }
    }

    private func path(
        for destination: PlozziOSDestination
    ) -> Binding<NavigationPath> {
        switch destination {
        case .home:
            $homePath
        case .search:
            $searchPath
        case .downloads:
            $downloadsPath
        case .settings:
            $settingsPath
        }
    }
}

private struct PlozziOSTabShell: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .home,
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                }
            }

            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .search,
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                }
            }

            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .downloads,
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                }
            }

            Tab("Settings", systemImage: "gear") {
                NavigationStack {
                    PlozziOSDestinationView(
                        destination: .settings,
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                }
            }
        }
    }
}

private struct PlozziOSDestinationView: View {
    let destination: PlozziOSDestination
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        switch destination {
        case .home:
            PlozziOSHomeLandingView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        case .search:
            PlozziOSSearchView(appModel: appModel)
                .id(appModel.accounts.map(\.credentialRevision))
        case .downloads:
            PlozziOSDownloadsView(model: appModel.downloads)
                .id(appModel.profiles.activeProfileID)
        case .settings:
            PlozziOSSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        }
    }
}

private struct PlozziOSHomeLandingView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

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
        } else {
            PlozziOSHomeView(
                appModel: appModel,
                onAddServer: onAddServer
            )
            .id(appModel.accounts.map(\.credentialRevision))
        }
    }
}

#endif
