#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

/// Programmatic navigation to an item's detail page.
///
/// iOS pushes detail with inline `NavigationLink { … }`, which works for tapping
/// a card but gives the app no way to navigate *itself* — so
/// `Environment.mediaItemNavigator` was never installed, and every navigation
/// action ("Go to Season", "Go to Movie") was silently filtered out of iOS
/// context menus. tvOS installs one from its path-based stack and offers them.
///
/// This adds a value-typed destination alongside the existing links: the menu
/// sets the item, the stack builds the page once. Applied per navigation stack,
/// so a push lands in the tab the user is actually in.
private struct PlozziOSItemNavigationModifier: ViewModifier {
    let appModel: PlozziOSAppModel
    @State private var navigatedItem: MediaItem?

    func body(content: Content) -> some View {
        content
            .mediaItemNavigator { navigatedItem = $0 }
            .navigationDestination(item: $navigatedItem) { item in
                // Resolve against the best server for this title, the same way a
                // tapped card does, so a navigated push is not pinned to whichever
                // server happened to back the row it came from.
                let target = PlaybackSourceSelection.bestPlayItem(
                    item,
                    accounts: appModel.accountsProviders.resolvedActiveAccounts,
                    identitySources: appModel.identityIndex.identitySourcesProvider
                )
                if let provider = appModel.provider(for: target) {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: provider,
                        item: target,
                        seerService: appModel.seerService,
                        // An episode arriving through the menu is "Episode Info",
                        // which wants the episode itself. "Go to Season" hands
                        // over a season, so the two are distinguishable by kind.
                        presentsEpisodeAsSubject: target.kind == .episode
                    )
                } else {
                    ContentUnavailableView(
                        "Server unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This title's server is no longer connected.")
                    )
                }
            }
    }
}

extension View {
    /// Lets menu actions push an item's detail page within this navigation stack.
    func plozziOSItemNavigation(appModel: PlozziOSAppModel) -> some View {
        modifier(PlozziOSItemNavigationModifier(appModel: appModel))
    }
}
#endif
