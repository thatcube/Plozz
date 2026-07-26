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
struct PlozziOSLibraryRoute: Hashable {
    var title: String
    var containerID: String
    var containerKind: MediaItemKind
    var accountID: String?

    init(library: MediaLibrary, accountID: String?) {
        self.title = library.title
        self.containerID = library.id
        self.containerKind = library.kind
        self.accountID = accountID
    }
}

extension View {
    /// Installs the library-grid destination for a navigation stack.
    func plozziOSLibraryDestination(appModel: PlozziOSAppModel) -> some View {
        navigationDestination(for: PlozziOSLibraryRoute.self) { route in
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
                    settings: appModel.settings
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
}
#endif
