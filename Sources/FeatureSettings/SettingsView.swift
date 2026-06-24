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
            // One "Plex User" row per signed-in Plex account. Each row shows
            // the Home user currently bound to THAT account for the active
            // profile, with its Plex avatar, and drills into a picker scoped
            // to that one account.
            let plexAccts = plexAccountsForRows
            ForEach(Array(plexAccts.enumerated()), id: \.element.id) { _, account in
                plexLinkedUserRow(account: account, multiple: plexAccts.count > 1)
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
        case let .server(key):
            ServerDetailView(context: context, serverKey: key)
        }
    }

    // MARK: - Header (inside the profile container)

    /// Big avatar + name + switch button rendered as the *top* of the profile
    /// container card. Visually fused with the rows below (no card divider).
    private var profileHeaderInline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.32))
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    Image(systemName: activeProfile.avatarSymbol)
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 104, height: 104)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text("Active profile")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .textCase(.uppercase)
                            .tracking(1.2)
                    }
                    Text(activeProfile.name)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Settings below are saved on this profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onSwitchProfile) {
                    Label("Switch Profile", systemImage: "person.2.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                }
            }
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

    // MARK: - Plex linked user row (one per signed-in Plex account)

    /// All distinct signed-in Plex accounts. Each gets its own row so the
    /// active profile's Home-user choice can differ per Plex sign-in.
    private var plexAccountsForRows: [Account] {
        accounts.filter { $0.server.provider == .plex }
    }

    private func plexLinkedUserRow(account: Account, multiple: Bool) -> some View {
        // A nil binding MEANS "play as the account owner" (no Home-user switch,
        // no PIN). Render it as the owner so "default" and "explicitly picked
        // owner" look identical — they are the same thing semantically.
        let binding = activeProfile.homeUserBinding(forPlexAccount: account.id)
            ?? ownerBinding(for: account)
        return NavigationLink(value: SettingsRoute.plexUser(accountID: account.id)) {
            HStack(spacing: 16) {
                plexAvatar(for: binding, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(multiple ? "Plex User on \(account.server.name)" : "Plex User")
                        .font(.headline)
                    Text(plexLinkedUserSubtitle(for: binding))
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

    /// Synthetic binding representing the Plex account owner — derived from
    /// the signed-in Account (its userName + avatarURL), so we don't need to
    /// fetch Home users just to display the default identity. Owner never
    /// requires a PIN.
    private func ownerBinding(for account: Account) -> PlexHomeUserBinding? {
        let name = account.userName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return PlexHomeUserBinding(
            homeUserID: "",
            name: name,
            avatarURL: account.avatarURL?.absoluteString,
            requiresPIN: false
        )
    }

    /// Big circular Plex avatar — uses this binding's cached `avatarURL` so
    /// the row shows the real Plex profile photo, not just text + an icon.
    private func plexAvatar(for binding: PlexHomeUserBinding?, size: CGFloat) -> some View {
        let url = binding?.avatarURL.flatMap(URL.init(string:))
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

    private func plexLinkedUserSubtitle(for binding: PlexHomeUserBinding?) -> String {
        guard let binding, !binding.name.isEmpty else {
            return "Select Plex user"
        }
        return binding.requiresPIN == true ? "\(binding.name) • PIN required" : binding.name
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
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// Contained focus treatment for Settings rows. Default `.plain` on tvOS
/// draws an enlarged focus halo that overflows row bounds — with zero-spaced
/// rows it visibly bleeds into the neighbors and sits on top of dividers.
/// This style keeps focus INSIDE the row: a clipped rounded rect background
/// fills only the row's frame, no scale.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowButtonBody(configuration: configuration)
    }
}

private struct SettingsRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused
    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.35) : Color.clear, lineWidth: 2)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
