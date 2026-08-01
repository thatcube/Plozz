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
/// A person plus the server that listed them — see
/// ``EnvironmentValues/mediaPersonSourceNavigator``.
private struct PlozziOSPersonRoute: Identifiable, Hashable {
    let person: MediaPerson
    let sourceAccountID: String?

    var id: String { "\(person.id)#\(sourceAccountID ?? "")" }
}

private struct PlozziOSItemNavigationModifier: ViewModifier {
    let appModel: PlozziOSAppModel
    @State private var navigatedItem: MediaItem?
    @State private var navigatedPerson: PlozziOSPersonRoute?

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
            .navigationDestination(item: $navigatedPerson) { route in
                let person = route.person
                let accounts = appModel.accountsProviders.resolvedActiveAccounts
                PersonDetailView(
                    person: person,
                    viewModel: PersonDetailViewModel(
                        person: person,
                        // The person's OWN server, by its own person id.
                        //
                        // Load STOPS here without one — the view model returns
                        // `.unavailable` before it ever fans out — so passing nil
                        // and relying on the by-name rung, as this briefly did,
                        // reported "nothing else in your library" for everybody.
                        // The account travels with the route because a person id
                        // means nothing to any other server.
                        //
                        // `resolveOptional`, never a fallback to the primary
                        // account: that sent Jellyfin and share person ids to
                        // Plex and got nothing back. No account means no credits,
                        // not wrong credits.
                        provider: route.sourceAccountID.flatMap { id in
                            accounts.first(where: { $0.account.id == id })?.provider
                        },
                        // Every OTHER signed-in server, asked by name, since
                        // person ids do not cross servers.
                        otherProviders: accounts
                            .filter { $0.account.id != route.sourceAccountID }
                            .map(\.provider),
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
            // Account-less: for surfaces that have a person but no idea which
            // server listed them. Their credits come from the keyless ladder and
            // whatever the other servers can match by name.
            .mediaPersonNavigator { navigatedPerson = .init(person: $0, sourceAccountID: nil) }
            .mediaPersonSourceNavigator { person, accountID in
                navigatedPerson = .init(person: person, sourceAccountID: accountID)
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
