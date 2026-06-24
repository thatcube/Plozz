#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles
import TraktService

/// Settings root — a hierarchical list of top-level rows that each push a
/// dedicated detail page.
///
/// The drill-down structure exists to (1) shorten the home-of-settings to a
/// scannable list rather than one long scroll of panels, and (2) make it
/// obvious that selecting a profile changes ALL settings while different
/// rows (Appearance / Captions / Playback / etc.) are independent.
///
/// We use a root `NavigationStack` (not a sheet) so pushed `NavigationLink`
/// destinations don't render blank — pushed pickers inside tvOS sheets are
/// the known IA pitfall this rewrite explicitly avoids.
public struct SettingsView: View {
    /// Typed routes for the Settings drill-down. Using `navigationDestination(for:)`
    /// (instead of `NavigationLink(destination:label:)` closures inside a
    /// ScrollView) is the pattern that reliably pushes onto the tab's
    /// NavigationStack on tvOS — the closure-based form sometimes hosts the
    /// destination *outside* the stack, so the Menu/Back button quits the app
    /// instead of popping back.
    private enum SettingsRoute: Hashable {
        case profile
        case servers
        case appearance
        case captions
        case spoilers
        case integrations
        case about
        case plexUser(accountID: String)
    }

    @State private var path: [SettingsRoute] = []

    private let captions: CaptionSettingsModel
    private let spoilers: SpoilerSettingsModel
    private let theme: ThemeSettingsModel
    private let homeVisibility: HomeLibraryVisibilityModel
    private let trakt: TraktService
    private let discoveredLibraries: LoadState<[AggregatedLibrary]>
    private let reloadLibraries: () async -> Void
    private let accounts: [Account]
    private let activeAccountID: String?
    private let profiles: [Profile]
    private let activeProfile: Profile
    private let askProfileOnStartup: Bool
    private let profilesEnabled: Bool
    private let appVersion: String
    private let appBuild: String
    private let repoURL: String
    private let isAccountIncludedInActiveProfile: (String) -> Bool
    private let onSetAccountIncluded: (String, Bool) -> Void
    private let onSetAskProfileOnStartup: (Bool) -> Void
    private let onEnableProfiles: () -> Void
    private let onDisableProfiles: () -> Void
    private let onSwitchProfile: () -> Void
    private let onSaveProfile: (ProfileDraft) -> Void
    private let onDeleteProfile: (String) -> Void
    private let onAddAccount: () -> Void
    private let onRemoveAccount: (Account) -> Void
    private let onSignOutAll: () -> Void
    private let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    private let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void

    public init(
        captions: CaptionSettingsModel,
        spoilers: SpoilerSettingsModel,
        theme: ThemeSettingsModel,
        homeVisibility: HomeLibraryVisibilityModel,
        trakt: TraktService,
        discoveredLibraries: LoadState<[AggregatedLibrary]>,
        reloadLibraries: @escaping () async -> Void,
        accounts: [Account],
        activeAccountID: String?,
        profiles: [Profile],
        activeProfile: Profile,
        askProfileOnStartup: Bool,
        profilesEnabled: Bool,
        appVersion: String,
        appBuild: String,
        repoURL: String,
        isAccountIncludedInActiveProfile: @escaping (String) -> Bool,
        onSetAccountIncluded: @escaping (String, Bool) -> Void,
        onSetAskProfileOnStartup: @escaping (Bool) -> Void,
        onEnableProfiles: @escaping () -> Void,
        onDisableProfiles: @escaping () -> Void,
        onSwitchProfile: @escaping () -> Void,
        onSaveProfile: @escaping (ProfileDraft) -> Void,
        onDeleteProfile: @escaping (String) -> Void,
        onAddAccount: @escaping () -> Void,
        onRemoveAccount: @escaping (Account) -> Void,
        onSignOutAll: @escaping () -> Void,
        plexHomeUsersFetcher: @escaping (String) async -> [PlexHomeUser],
        onSelectPlexHomeUser: @escaping (String, PlexHomeUser?) -> Void
    ) {
        self.captions = captions
        self.spoilers = spoilers
        self.theme = theme
        self.homeVisibility = homeVisibility
        self.trakt = trakt
        self.discoveredLibraries = discoveredLibraries
        self.reloadLibraries = reloadLibraries
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.askProfileOnStartup = askProfileOnStartup
        self.profilesEnabled = profilesEnabled
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.repoURL = repoURL
        self.isAccountIncludedInActiveProfile = isAccountIncludedInActiveProfile
        self.onSetAccountIncluded = onSetAccountIncluded
        self.onSetAskProfileOnStartup = onSetAskProfileOnStartup
        self.onEnableProfiles = onEnableProfiles
        self.onDisableProfiles = onDisableProfiles
        self.onSwitchProfile = onSwitchProfile
        self.onSaveProfile = onSaveProfile
        self.onDeleteProfile = onDeleteProfile
        self.onAddAccount = onAddAccount
        self.onRemoveAccount = onRemoveAccount
        self.onSignOutAll = onSignOutAll
        self.plexHomeUsersFetcher = plexHomeUsersFetcher
        self.onSelectPlexHomeUser = onSelectPlexHomeUser
    }

    private var context: SettingsContext {
        SettingsContext(
            captions: captions,
            spoilers: spoilers,
            theme: theme,
            homeVisibility: homeVisibility,
            discoveredLibraries: discoveredLibraries,
            reloadLibraries: reloadLibraries,
            accounts: accounts,
            activeAccountID: activeAccountID,
            profiles: profiles,
            activeProfile: activeProfile,
            askProfileOnStartup: askProfileOnStartup,
            profilesEnabled: profilesEnabled,
            isAccountIncludedInActiveProfile: isAccountIncludedInActiveProfile,
            onSetAccountIncluded: onSetAccountIncluded,
            onSetAskProfileOnStartup: onSetAskProfileOnStartup,
            onEnableProfiles: onEnableProfiles,
            onDisableProfiles: onDisableProfiles,
            onSwitchProfile: onSwitchProfile,
            onSaveProfile: onSaveProfile,
            onDeleteProfile: onDeleteProfile,
            onAddAccount: onAddAccount,
            onRemoveAccount: onRemoveAccount,
            onSignOutAll: onSignOutAll,
            plexHomeUsersFetcher: plexHomeUsersFetcher,
            onSelectPlexHomeUser: onSelectPlexHomeUser
        )
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // The profile-owned settings live INSIDE the profile's own
                    // container, so the "this profile saves these settings"
                    // relationship is visible at a glance. Switching profiles
                    // swaps everything inside this container at once.
                    profileContainer

                    // Household-level controls stay outside the profile
                    // container — they're not scoped to one profile.
                    householdContainer
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
            }
            .task { await reloadLibraries() }
        }
    }

    // MARK: - Profile container (header + all settings this profile owns)

    /// One visual container that wraps the active profile's identity AND
    /// every setting it saves. The profile header is the *top* of the same
    /// card the rows are nested in — so it reads as "the profile owns these."
    @ViewBuilder
    private var profileContainer: some View {
        if profilesEnabled {
            VStack(alignment: .leading, spacing: 0) {
                profileHeaderInline
                Divider()
                    .padding(.horizontal, 28)
                profileOwnedRows
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 2)
            )
        } else {
            // Single-profile (solo) household: the same nested container,
            // but framed as plain "Settings" with an explicit Enable Profiles
            // entry point at the top.
            VStack(alignment: .leading, spacing: 0) {
                soloHeader
                Divider().padding(.horizontal, 28)
                profileOwnedRows
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    /// Rows nested inside the profile container. Order is deliberate:
    /// identity-shaping rows first (Plex linked user, Server accounts), then
    /// presentation (Appearance, Captions, Spoilers), then Integrations, then
    /// profile management (edit/delete, ask-on-startup). Each row pushes its
    /// own detail page via the root NavigationStack.
    @ViewBuilder
    private var profileOwnedRows: some View {
        VStack(spacing: 0) {
            // Show the Plex Home user row whenever at least one Plex account
            // is signed in. Tapping it opens the picker, which lists every
            // signed-in Plex account's Home users with their Plex avatars.
            if let plexAccountID = primaryPlexAccountID {
                plexLinkedUserRow(accountID: plexAccountID)
                Divider()
            }
            navRow("Server Accounts", icon: "person.2.crop.square.stack",
                   value: serverAccountsSummary,
                   route: .servers)
            Divider()
            navRow("Appearance", icon: "paintpalette",
                   value: theme.theme.displayName,
                   route: .appearance)
            Divider()
            navRow("Captions", icon: "captions.bubble",
                   value: nil,
                   route: .captions)
            Divider()
            navRow("Spoilers", icon: "eye.slash",
                   value: spoilers.settings.isEnabled ? "On" : "Off",
                   route: .spoilers)
            Divider()
            navRow("Integrations", icon: "link",
                   value: traktSummary,
                   route: .integrations)
            if profilesEnabled {
                Divider()
                navRow("Manage Profiles", icon: "person.crop.circle",
                       value: profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles",
                       route: .profile)
            } else {
                Divider()
                enableProfilesRow
            }
        }
    }

    /// "About & Sign Out" lives outside the profile container — it's
    /// household-scoped (app version, repo, sign out all accounts) not
    /// per-profile.
    private var householdContainer: some View {
        SettingsPanel {
            navRow("About & Sign Out", icon: "info.circle",
                   value: nil,
                   route: .about)
        }
    }

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .profile:
            ProfileDetailView(
                context: context,
                appVersion: appVersion,
                appBuild: appBuild,
                repoURL: repoURL
            )
        case .servers:
            ServersAndLibrariesDetailView(context: context)
        case .appearance:
            AppearanceDetailView(theme: theme)
        case .captions:
            CaptionsDetailView(captions: captions)
        case .spoilers:
            SpoilersDetailView(spoilers: spoilers)
        case .integrations:
            IntegrationsDetailView(trakt: trakt)
        case .about:
            AboutDetailView(
                version: appVersion,
                build: appBuild,
                repoURL: repoURL,
                canSignOut: !accounts.isEmpty,
                onSignOutAll: onSignOutAll
            )
        case let .plexUser(accountID):
            PlexLinkedUserDetailView(context: context, accountID: accountID)
        }
    }

    // MARK: - Header (inside the profile container)

    /// Big avatar + name + switch button rendered as the *top* of the profile
    /// container card. Visually fused with the rows below (no card divider).
    private var profileHeaderInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.28))
                    Image(systemName: activeProfile.avatarSymbol)
                        .font(.largeTitle)
                        .foregroundStyle(.primary)
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings for")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(activeProfile.name)
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Button(action: onSwitchProfile) {
                    Label("Switch Profile", systemImage: "person.2.circle")
                }
            }
            Text("Everything below is saved on this profile. Switching profiles swaps it all at once.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }

    private var soloHeader: some View {
        HStack(spacing: 20) {
            Image(systemName: "gearshape.fill")
                .font(.largeTitle)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.primary.opacity(0.10)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.title2.weight(.semibold))
                Text("Used across the household. Enable profiles to give each viewer their own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(28)
    }

    // MARK: - Plex linked user row (prominent, with Plex avatar)

    /// First signed-in Plex account, used as the row's default account.
    /// (The picker itself groups every Plex account when there are multiple.)
    private var primaryPlexAccountID: String? {
        accounts.first { $0.server.provider == .plex }?.id
    }

    private func plexLinkedUserRow(accountID: String) -> some View {
        NavigationLink(value: SettingsRoute.plexUser(accountID: accountID)) {
            HStack(spacing: 16) {
                plexAvatar(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plex User")
                        .font(.headline)
                    Text(plexLinkedUserSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Big circular Plex avatar — uses the cached `plexHomeUserAvatarURL` so
    /// the row shows the real Plex profile photo, not just text + an icon.
    private func plexAvatar(size: CGFloat) -> some View {
        let urlString = activeProfile.plexHomeUserAvatarURL
        let url = urlString.flatMap(URL.init(string:))
        return ZStack {
            Circle()
                .fill(ProviderIcon.tint(.plex).opacity(0.18))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        ProviderIcon(provider: .plex, size: size * 0.55)
                    }
                }
            } else {
                ProviderIcon(provider: .plex, size: size * 0.55)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ProviderIcon.tint(.plex).opacity(0.45), lineWidth: 1.5))
    }

    private var plexLinkedUserSubtitle: String {
        if let name = activeProfile.plexHomeUserName, !name.isEmpty {
            return activeProfile.plexHomeUserRequiresPIN == true
                ? "\(name) • PIN required"
                : name
        }
        return "Tap to pick your Plex Home user"
    }

    // MARK: - Enable profiles row (single-profile household)

    private var enableProfilesRow: some View {
        Button(action: onEnableProfiles) {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Profiles")
                        .font(.headline)
                    Text("Add separate household profiles so each person gets their own Home, watch history, and preferences.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var serverAccountsSummary: String {
        if accounts.isEmpty { return "Add a server" }
        let included = accounts.filter { isAccountIncludedInActiveProfile($0.id) }.count
        if profilesEnabled, included != accounts.count {
            return "\(included) of \(accounts.count)"
        }
        return accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
    }

    private var traktSummary: String? {
        switch trakt.phase {
        case let .connected(name): return name
        case .connecting: return "Connecting…"
        case .disconnected: return "Off"
        case .unavailable: return "Unavailable"
        case .error: return "Error"
        case .unknown: return nil
        }
    }

    /// Settings drill-down row. Uses a value-based `NavigationLink` that pushes
    /// onto the root `NavigationStack` via `navigationDestination(for:)` — this
    /// is the only pattern that reliably keeps the Menu/Back button bound to
    /// "pop one level" on tvOS. Closure-based `NavigationLink(destination:)`
    /// inside a ScrollView occasionally hosts the destination outside the
    /// stack, in which case Menu quits the app.
    @ViewBuilder
    private func navRow(
        _ title: String,
        icon: String,
        value: String?,
        route: SettingsRoute
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
