#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import MetadataKit
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
    @State private var navigatedPerson: MediaPerson?

    func body(content: Content) -> some View {
        content
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
            .navigationDestination(item: $navigatedPerson) { person in
                let accounts = appModel.accountsProviders.resolvedActiveAccounts
                PersonDetailView(
                    person: person,
                    viewModel: PersonDetailViewModel(
                        person: person,
                        // NO id-scoped provider, deliberately.
                        //
                        // A person id is only meaningful to the server that
                        // issued it, and `MediaPerson` does not carry which one
                        // that was — tvOS supplies it separately, from the page
                        // that loaded the title. This router is installed per
                        // navigation stack and has no such context, so it asks
                        // every server BY NAME instead, which is the same rung
                        // the view model falls back to and cannot return another
                        // server's person by mistake. It costs one request per
                        // server; sending a Jellyfin id to Plex costs a wrong
                        // answer, which is worse.
                        provider: nil,
                        otherProviders: accounts.map(\.provider),
                        // Keyless, so it works for every user out of the box, and
                        // only reached when no server stored a biography.
                        biographyProviders: [WikipediaPersonBiographyProvider()],
                        // The same ladder the in-player Cast card uses — without
                        // it this page can only answer with what the viewer
                        // already owns, which is not what "known for" means.
                        creditsProviders: PlayerCastCredits.providers,
                        artworkResolver: PlayerCastCredits.artworkResolver
                    ),
                    onSelectItem: { navigatedItem = $0 }
                )
            }
            // Applied *after* the destinations so the environment encloses them
            // and pushed pages inherit the router. The other order leaves the
            // destination outside the environment, so navigation actions are
            // dropped from every menu on a pushed page.
            .mediaItemNavigator { navigatedItem = $0 }
            .mediaPersonNavigator { navigatedPerson = $0 }
    }
}

extension View {
    /// Lets menu actions push an item's detail page within this navigation stack.
    func plozziOSItemNavigation(appModel: PlozziOSAppModel) -> some View {
        modifier(PlozziOSItemNavigationModifier(appModel: appModel))
    }
}
#endif
