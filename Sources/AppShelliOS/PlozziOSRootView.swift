#if os(iOS)
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var appModel = PlozziOSAppModel()
    @State private var selection: PlozziOSDestination? = .home
    @State private var showingAddServer = false

    public init() {}

    public var body: some View {
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
        .sheet(isPresented: $showingAddServer) {
            AddServerView(appModel: appModel)
        }
    }
}

private enum PlozziOSDestination: String, CaseIterable, Identifiable {
    case home
    case search
    case settings

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
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
            ContentUnavailableView(
                "Search",
                systemImage: "magnifyingglass",
                description: Text("Search becomes available after Home loads your libraries.")
            )
            .navigationTitle("Search")
        case .settings:
            PlozziOSAccountSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
            .navigationTitle("Settings")
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
                Text("Connect Jellyfin, Emby, or Plex to start watching.")
            } actions: {
                Button("Add Server", action: onAddServer)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Home")
        } else {
            List {
                Section("Connected servers") {
                    ForEach(appModel.accounts) { account in
                        Label {
                            VStack(alignment: .leading) {
                                Text(account.server.name)
                                Text(account.userName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus", action: onAddServer)
                }
            }
        }
    }
}

private struct PlozziOSAccountSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        List {
            Section("Servers") {
                ForEach(appModel.accounts) { account in
                    VStack(alignment: .leading) {
                        Text(account.server.name)
                        Text(account.userName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            appModel.removeAccount(id: account.id)
                        }
                    }
                }

                Button("Add Server", systemImage: "plus", action: onAddServer)
            }

            if let accountError = appModel.accountError {
                Section {
                    Label(accountError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
#endif
