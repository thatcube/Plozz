#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Exactly what the Libraries screen needs, and nothing else.
///
/// `SettingsContext` carries 61 fields because Settings has 61 things to do;
/// the Libraries screen reads ten of them. Depending on the whole context meant
/// the screen could only ever be rendered from inside Settings — so the new
/// profile setup step grew a second, worse copy of the same list instead, with
/// libraries detached from their servers and its own focus bugs.
///
/// Narrowing the dependency is what makes one screen serve both.
public struct ProfileLibrariesScope {
    /// Where this screen is being shown, which is the only thing that differs
    /// between the two uses.
    ///
    /// One screen, two contexts — rather than two screens. The controls are
    /// identical (that's the whole reason setup reuses this page); what changes
    /// is what the person is in the middle of. In Settings they're adjusting a
    /// profile they already have. During setup they're answering a question they
    /// were just asked, and actions that lead OUT of the flow — signing a new
    /// server in to the whole device — don't belong mid-flight.
    public enum Presentation {
        case settings
        case profileSetup
    }

    public var presentation: Presentation
    public var accounts: [Account]
    public var activeProfile: Profile
    public var discoveredLibraries: LoadState<[AggregatedLibrary]>
    /// Accounts whose libraries are being refreshed after a toggle.
    public var refreshingLibraryAccountIDs: Set<String>
    /// Accounts whose last library fetch failed, so the UI can say "couldn't
    /// reach this server" rather than "no libraries".
    public var unreachableLibraryAccountIDs: Set<String>
    public var reloadLibraries: () async -> Void
    public var homeVisibility: HomeLibraryVisibilityModel
    public var isAccountIncludedInActiveProfile: (String) -> Bool
    public var onSetAccountIncluded: (String, Bool) -> Void
    public var onAddAccount: () -> Void
    public var plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    public var onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void

    public init(
        presentation: Presentation = .settings,
        accounts: [Account],
        activeProfile: Profile,
        discoveredLibraries: LoadState<[AggregatedLibrary]>,
        refreshingLibraryAccountIDs: Set<String>,
        unreachableLibraryAccountIDs: Set<String>,
        reloadLibraries: @escaping () async -> Void,
        homeVisibility: HomeLibraryVisibilityModel,
        isAccountIncludedInActiveProfile: @escaping (String) -> Bool,
        onSetAccountIncluded: @escaping (String, Bool) -> Void,
        onAddAccount: @escaping () -> Void,
        plexHomeUsersFetcher: @escaping (String) async -> [PlexHomeUser],
        onSelectPlexHomeUser: @escaping (String, PlexHomeUser?) -> Void
    ) {
        self.presentation = presentation
        self.accounts = accounts
        self.activeProfile = activeProfile
        self.discoveredLibraries = discoveredLibraries
        self.refreshingLibraryAccountIDs = refreshingLibraryAccountIDs
        self.unreachableLibraryAccountIDs = unreachableLibraryAccountIDs
        self.reloadLibraries = reloadLibraries
        self.homeVisibility = homeVisibility
        self.isAccountIncludedInActiveProfile = isAccountIncludedInActiveProfile
        self.onSetAccountIncluded = onSetAccountIncluded
        self.onAddAccount = onAddAccount
        self.plexHomeUsersFetcher = plexHomeUsersFetcher
        self.onSelectPlexHomeUser = onSelectPlexHomeUser
    }
}

extension SettingsContext {
    /// The Libraries screen's slice of this context.
    var librariesScope: ProfileLibrariesScope {
        ProfileLibrariesScope(
            accounts: accounts,
            activeProfile: activeProfile,
            discoveredLibraries: discoveredLibraries,
            refreshingLibraryAccountIDs: refreshingLibraryAccountIDs,
            unreachableLibraryAccountIDs: unreachableLibraryAccountIDs,
            reloadLibraries: reloadLibraries,
            homeVisibility: homeVisibility,
            isAccountIncludedInActiveProfile: isAccountIncludedInActiveProfile,
            onSetAccountIncluded: onSetAccountIncluded,
            onAddAccount: onAddAccount,
            plexHomeUsersFetcher: plexHomeUsersFetcher,
            onSelectPlexHomeUser: onSelectPlexHomeUser
        )
    }
}
#endif
