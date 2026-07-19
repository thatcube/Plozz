#if os(iOS)
import CoreModels
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var appModel = PlozziOSAppModel()
    @State private var selection: PlozziOSDestination? = .home
    @State private var showingAddServer = false

    public init() {}

    public var body: some View {
        let pinRequest = appModel.plexHomeUsers.pendingPlexPINRequest

        Group {
            if horizontalSizeClass == .regular {
                PlozziOSSplitShell(
                    selection: $selection,
                    appModel: appModel,
                    onAddServer: { showingAddServer = true }
                )
            } else {
                PlozziOSTabShell(
                    appModel: appModel,
                    onAddServer: { showingAddServer = true }
                )
            }
        }
        .environment(appModel)
        .id(
            "\(appModel.profiles.activeProfileID)#"
                + "\(appModel.plexHomeUsers.plexIdentityGeneration)"
        )
        .sheet(isPresented: $showingAddServer) {
            AddServerView(appModel: appModel)
        }
        .sheet(
            item: Binding(
                get: { pinRequest },
                set: { request in
                    if request == nil {
                        appModel.plexHomeUsers.dismissPlexPINIfPresented()
                    }
                }
            )
        ) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
        }
        .preferredColorScheme(appModel.settings.theme.theme.preferredColorScheme)
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
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        NavigationSplitView {
            List(PlozziOSDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
            }
            .navigationTitle("Plozz")
        } detail: {
            NavigationStack {
                PlozziOSDestinationView(
                    destination: selection ?? .home,
                    appModel: appModel,
                    onAddServer: onAddServer
                )
            }
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

private extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .pureBlack: .dark
        }
    }
}
#endif
