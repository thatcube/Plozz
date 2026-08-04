#if canImport(SwiftUI)
import CoreModels
import FeatureSettings
import Foundation
import Observation

/// Library discovery for the new-profile setup step.
///
/// Settings discovers libraries inside `MainTabView`; the setup step is a cover
/// presented above everything, so it needs its own small loader rather than
/// reaching into that view's state. Same discovery model underneath — only the
/// ownership differs.
@MainActor
@Observable
final class ProfileSetupLibrariesLoader {
    var state: LoadState<[AggregatedLibrary]> = .idle
    var refreshingAccountIDs: Set<String> = []
    var unreachableAccountIDs: Set<String> = []

    @ObservationIgnored private let discovery = LibraryDiscoveryModel()
    @ObservationIgnored private var revision = 0

    /// Rediscovers over the accounts the profile currently includes. Safe to call
    /// on every toggle: a newer call supersedes an in-flight one.
    func reload(appState: AppState) async {
        revision += 1
        let mine = revision
        let scoped = appState.accountsProviders.resolvedActiveAccounts.filter {
            appState.profileFlow.isAccountIncludedInActiveProfile($0.account.id)
        }
        refreshingAccountIDs = Set(scoped.map(\.account.id))
        if state.value == nil { state = .loading }
        let discovered = await discovery.libraryDiscovery(from: scoped)
        guard mine == revision else { return }
        refreshingAccountIDs = []
        unreachableAccountIDs = discovered.unreachableAccountIDs
        state = .loaded(discovered.libraries)
    }
}

extension AppState {
    /// Builds the Libraries screen's dependencies from app state, so the setup
    /// step can render the real screen instead of a copy.
    func profileLibrariesScope(
        librariesStore: ProfileSetupLibrariesLoader
    ) -> ProfileLibrariesScope {
        ProfileLibrariesScope(
            presentation: .profileSetup,
            accounts: accountsProviders.accounts,
            activeProfile: profilesModel.activeProfile,
            discoveredLibraries: librariesStore.state,
            refreshingLibraryAccountIDs: librariesStore.refreshingAccountIDs,
            unreachableLibraryAccountIDs: librariesStore.unreachableAccountIDs,
            reloadLibraries: { [weak self] in
                guard let self else { return }
                await librariesStore.reload(appState: self)
            },
            homeVisibility: profileSettings.homeLibraryVisibilityModel,
            isAccountIncludedInActiveProfile: { [weak self] in
                self?.profileFlow.isAccountIncludedInActiveProfile($0) ?? false
            },
            onSetAccountIncluded: { [weak self] id, included in
                self?.profileFlow.setAccount(id, includedInActiveProfile: included)
            },
            // Not offered during setup — see `ProfileLibrariesScope.Presentation`.
            onAddAccount: {},
            onAddUser: { [weak self] server in self?.selectServer(server) },
            plexHomeUsersFetcher: { [weak self] accountID in
                await self?.plexHomeUsers.plexHomeUsers(forAccountID: accountID) ?? []
            },
            onSelectPlexHomeUser: { [weak self] accountID, user in
                self?.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: accountID, user: user)
            }
        )
    }
}
#endif
