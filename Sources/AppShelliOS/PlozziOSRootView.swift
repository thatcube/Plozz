#if os(iOS)
import SwiftUI

public struct PlozziOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: PlozziOSDestination? = .home

    public init() {}

    public var body: some View {
        if horizontalSizeClass == .regular {
            PlozziOSSplitShell(selection: $selection)
        } else {
            PlozziOSTabShell()
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

    var body: some View {
        NavigationSplitView {
            List(PlozziOSDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
            }
            .navigationTitle("Plozz")
        } detail: {
            NavigationStack {
                PlozziOSDestinationView(destination: selection ?? .home)
            }
        }
    }
}

private struct PlozziOSTabShell: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    PlozziOSDestinationView(destination: .home)
                }
            }

            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack {
                    PlozziOSDestinationView(destination: .search)
                }
            }

            Tab("Settings", systemImage: "gear") {
                NavigationStack {
                    PlozziOSDestinationView(destination: .settings)
                }
            }
        }
    }
}

private struct PlozziOSDestinationView: View {
    let destination: PlozziOSDestination

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: destination.systemImage)
        } description: {
            Text("Connect a media source to start building your library.")
        }
        .navigationTitle(destination.title)
    }
}
#endif
