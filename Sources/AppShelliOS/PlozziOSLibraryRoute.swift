#if os(iOS)
import SwiftUI
import CoreModels
import FeatureHomeCore

/// A pushed library grid, addressed by value rather than by an eagerly-built view.
///
/// `NavigationLink { PlozziOSLibraryGridView(viewModel: LibraryBrowseViewModel(…)) }`
/// rebuilds its destination — and a brand-new view model — every time the
/// *source* body re-evaluates, even while that destination is already pushed.
/// Opening a movie makes the detail page search the other configured servers for
/// the same title; when those responses land they touch observed state that Home
/// reads, Home re-evaluates, and the grid sitting under the detail page is
/// remounted. Its `.task` then re-runs `loadFirstPage()`, which sets
/// `state = .loading` and clears `loaded`, so returning from the detail page
/// showed a reloading grid scrolled back to the top. Measured on device: exactly
/// one reload per movie opened.
///
/// A value-typed route hands ownership of the destination to the navigation
/// stack, which builds it once for the life of the push. The route deliberately
/// carries only `Hashable` identity — the provider is resolved inside the
/// destination builder, since providers are reference types whose identity would
/// otherwise re-trigger the same rebuild.
struct PlozziOSLibraryRoute: Hashable, Identifiable {
    var title: String   // l10n:content — library name from the server
    var containerID: String
    var containerKind: MediaItemKind
    var accountID: String?

    /// Stable across the value's lifetime so it can also drive a
    /// `navigationDestination(item:)` push (the screenshot router's path). The
    /// server-scoped container id is already unique per library.
    var id: String { "\(accountID ?? "")#\(containerID)" }

    init(library: MediaLibrary, accountID: String?) {
        self.title = library.title
        self.containerID = library.id
        self.containerKind = library.kind
        self.accountID = accountID
    }
}

/// The library grid a ``PlozziOSLibraryRoute`` resolves to.
///
/// Extracted from the destination closure so the value-typed push (from a
/// `NavigationLink`) and the programmatic push (the screenshot router's
/// `navigationDestination(item:)`) build the identical page rather than two
/// copies that could drift.
struct PlozziOSLibraryDestinationView: View {
    let appModel: PlozziOSAppModel
    let route: PlozziOSLibraryRoute

    var body: some View {
        if let provider = route.accountID.flatMap({
            appModel.accountsProviders.provider(forAccountID: $0)
        }) ?? appModel.accountsProviders.primaryProvider {
            PlozziOSLibraryGridView(
                viewModel: LibraryBrowseViewModel(
                    provider: provider,
                    containerID: route.containerID,
                    containerKind: route.containerKind,
                    sourceAccountID: route.accountID
                ),
                title: route.title,
                provider: provider,
                settings: appModel.settings,
                scanStatus: appModel.shareScanStatus
            )
        } else {
            ContentUnavailableView(
                "Server unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This library's server is no longer connected.")
            )
        }
    }
}

extension View {
    /// Installs the library-grid destination for a navigation stack.
    func plozziOSLibraryDestination(appModel: PlozziOSAppModel) -> some View {
        navigationDestination(for: PlozziOSLibraryRoute.self) { route in
            PlozziOSLibraryDestinationView(appModel: appModel, route: route)
        }
    }
}
#endif
