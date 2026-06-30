#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles
import TraktService
import SimklService
import AniListService
import MALService

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
    @State private var confirmSignOutAll = false

    private let captions: CaptionSettingsModel
    private let spoilers: SpoilerSettingsModel
    private let playback: PlaybackSettingsModel
    private let subtitlePolicy: SubtitlePolicyModel
    private let theme: ThemeSettingsModel
    private let nightShift: NightShiftSettingsModel
    private let homeVisibility: HomeLibraryVisibilityModel
    private let trakt: TraktService
    private let simkl: SimklService
    private let anilist: AniListService
    private let mal: MALService
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
        playback: PlaybackSettingsModel,
        subtitlePolicy: SubtitlePolicyModel,
        theme: ThemeSettingsModel,
        nightShift: NightShiftSettingsModel,
        homeVisibility: HomeLibraryVisibilityModel,
        trakt: TraktService,
        simkl: SimklService,
        anilist: AniListService,
        mal: MALService,
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
        self.playback = playback
        self.subtitlePolicy = subtitlePolicy
        self.theme = theme
        self.nightShift = nightShift
        self.homeVisibility = homeVisibility
        self.trakt = trakt
        self.simkl = simkl
        self.anilist = anilist
        self.mal = mal
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
            playback: playback,
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
                VStack(alignment: .leading, spacing: 36) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // The profile-owned settings live INSIDE the profile's own
                    // container, so the "this profile saves these settings"
                    // relationship is visible at a glance. Switching profiles
                    // swaps everything inside this container at once.
                    profileContainer

                    // About + Attributions + Sign Out render INLINE at the
                    // bottom of the main page (no drill-down for About). Only
                    // Attributions & Licensing pushes one level deeper.
                    aboutAndSignOut
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 48)
            }
            .scrollClipDisabled()
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
                    // Native tvOS hides the tab bar on drill-down pages; our
                    // Settings tab is a TabView tab hosting a NavigationStack,
                    // so pushed details would otherwise still show the tab
                    // strip on top. Hiding it here makes every detail render
                    // full-screen and the root list restores the bar on pop.
                    .toolbar(.hidden, for: .tabBar)
            }
            .task { await reloadLibraries() }
        }
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Sign Out", role: .destructive, action: onSignOutAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every Plex and Jellyfin sign-in on this Apple TV. You'll need to sign in again.")
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
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
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
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }

    /// Rows nested inside the profile container. Order is deliberate:
    /// identity-shaping rows first (Plex linked user, Server accounts), then
    /// presentation (Appearance, Captions, Spoilers), then Trackers, then
    /// profile management (edit/delete, ask-on-startup). Each row pushes its
    /// own detail page via the root NavigationStack.
    @ViewBuilder
    private var profileOwnedRows: some View {
        // Inter-row spacing replaces the previous dividers: it lets the
        // contained focus lift breathe without crossing into a neighbor row
        // or sitting on top of a divider line.
        VStack(spacing: 14) {
            // One "Plex User" row per signed-in Plex account.
            let plexAccts = plexAccountsForRows
            ForEach(Array(plexAccts.enumerated()), id: \.element.id) { _, account in
                plexLinkedUserRow(account: account, multiple: plexAccts.count > 1)
            }
            navRow("Server Accounts", icon: "person.2.crop.square.stack",
                   value: serverAccountsSummary,
                   route: .servers)
            navRow("Appearance", icon: "paintpalette",
                   value: theme.theme.displayName,
                   route: .appearance)
            navRow("Night Shift", icon: "moon.stars",
                   value: nightShift.settings.isEnabled ? "On" : "Off",
                   route: .nightShift)
            navRow("Playback", icon: "play.rectangle",
                   value: playback.settings.skipIntros == .off ? nil : "Skip: \(playback.settings.skipIntros.title)",
                   route: .playback)
            navRow("Spoilers", icon: "eye.slash",
                   value: spoilers.settings.isEnabled ? "On" : "Off",
                   route: .spoilers)
            navRow("Trackers — Trakt, Simkl, AniList, MyAnimeList", icon: "link",
                   value: nil,
                   route: .integrations)
            if profilesEnabled {
                navRow("Manage Profiles", icon: "person.crop.circle",
                       value: profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles",
                       route: .profile)
            } else {
                enableProfilesRow
            }
        }
    }

    /// About info + Attributions entry + Sign Out, rendered INLINE at the
    /// bottom of the main Settings page. About no longer drills in — only
    /// "Attributions & Licensing" pushes one level deeper. Spacing here mirrors
    /// the roomy cadence of the About panel itself.
    @ViewBuilder
    private var aboutAndSignOut: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Self-contained focusable inverted-card panel (logo / version /
            // build / disclaimers / QR) — perfect to drop in inline.
            SettingsAboutSection(version: appVersion, build: appBuild, repoURL: repoURL)

            // The one acceptable deeper page: open-source credits & licensing.
            navRow("Attributions & Licensing", icon: "doc.text.magnifyingglass",
                   value: nil,
                   route: .attributions)

            // The only Sign-Out-All entry point now lives here, inline, guarded
            // by the are-you-sure confirmation alert on the root view.
            if !accounts.isEmpty {
                signOutAllRow
            }
        }
    }

    /// Destructive "Sign Out of All Accounts" row. Keeps the red tint on both
    /// idle and the inverted focus card (legible on white or black), and arms
    /// the confirmation alert rather than signing out immediately.
    private var signOutAllRow: some View {
        Button(role: .destructive) {
            confirmSignOutAll = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 30, height: 30)
                Text("Sign Out of All Accounts").font(.callout.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
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
        case .nightShift:
            NightShiftDetailView(model: nightShift)
        case .playback:
            PlaybackDetailView(playback: playback, captions: captions, subtitlePolicy: subtitlePolicy)
        case .captions:
            CaptionsDetailView(captions: captions)
        case .spoilers:
            SpoilersDetailView(spoilers: spoilers)
        case .integrations:
            IntegrationsDetailView(trakt: trakt, simkl: simkl, anilist: anilist, mal: mal, playback: playback, serverCount: activeProfileServerCount)
        case .attributions:
            AttributionsDetailView()
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
                ProfileAvatarView(profile: activeProfile, size: 104)
                    .overlay(
                        Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    )
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)

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

                    signedInToCluster
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

    /// Compact, read-only "Signed in to" glance under the active-profile
    /// header. Purely informational — the Server Accounts row remains the
    /// management/drill-in entry point, so this is a glance, not an action.
    /// Capped to three entries with a trailing "+N more" so a busy household
    /// stays one line.
    @ViewBuilder
    private var signedInToCluster: some View {
        if !accounts.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                Text("Signed in to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.0)
                let visible = Array(accounts.prefix(3))
                let overflow = max(0, accounts.count - visible.count)
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 {
                        Text("·")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ProviderIcon(provider: account.server.provider, size: 26)
                        AccountAvatar(name: account.userName, imageURL: account.avatarURL, size: 22)
                        Text(signedInLabel(for: account))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if overflow > 0 {
                    Text("· +\(overflow) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func signedInLabel(for account: Account) -> String {
        let name = account.userName.trimmingCharacters(in: .whitespaces)
        let providerName = account.server.provider.displayName
        if name.isEmpty { return providerName }
        return "\(name)'s \(providerName)"
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
                plexAvatar(for: binding, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(multiple ? "Plex User on \(account.server.name)" : "Plex User")
                        .font(.callout.weight(.medium))
                    Text(plexLinkedUserSubtitle(for: binding))
                        .font(.subheadline)
                        .settingsRowSecondary()
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsRowSecondary()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
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
                rowIcon("person.crop.circle.badge.plus")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Profiles")
                        .font(.callout.weight(.medium))
                    Text("Add separate household profiles so each person gets their own Home, watch history, and preferences.")
                        .font(.footnote)
                        .settingsRowSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsRowSecondary()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
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

    /// Number of distinct servers the active profile can watch from. Cross-server
    /// watch-status sync is only meaningful when this is 2+ (otherwise there's
    /// nowhere to fan out to), so the Trackers page uses it to gate that toggle.
    private var activeProfileServerCount: Int {
        let relevant = profilesEnabled
            ? accounts.filter { isAccountIncludedInActiveProfile($0.id) }
            : accounts
        return Set(relevant.map { $0.server.id }).count
    }

    /// Shared leading icon for every Settings row. Explicit point size +
    /// fixed square frame so glyphs of different widths optically align with
    /// the row title and stay consistent across rows.
    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .frame(width: 30, height: 30)
            .settingsRowIcon()
    }

    @ViewBuilder
    private func navRow(
        _ title: String,
        icon: String,
        value: String?,
        route: SettingsRoute
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                rowIcon(icon)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .settingsRowSecondary()
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsRowSecondary()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }
}

#endif
