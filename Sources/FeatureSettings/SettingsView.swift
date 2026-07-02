#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles
import TraktService
import SimklService
import AniListService
import MALService
import LastFmService

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
    /// Presents the profile editor sheet for the active profile (Edit button in
    /// the profile header). Mirrors the editor flow in ``ProfileDetailView``.
    @State private var editingProfile: Profile?

    /// Shared sizing for the two identity headers (This Apple TV + the active
    /// profile) so their avatar/icon and title read as the same component. The
    /// circle is sized to sit between the old TV glyph (64) and profile avatar
    /// (104), roughly the combined height of the title + subtitle lines.
    private static let identityAvatarSize: CGFloat = 84
    private static let identityTitleFont: Font = .system(size: 36, weight: .bold)

    /// Caps the root "Settings" page content and centers it, so the profile
    /// card and About/Sign Out list don't stretch edge-to-edge on a wide TV.
    /// Tune this single value to make the page wider/narrower.
    private static let contentMaxWidth: CGFloat = PlozzTheme.Metrics.settingsContentMaxWidth

    private let captions: CaptionSettingsModel
    private let spoilers: SpoilerSettingsModel
    private let playback: PlaybackSettingsModel
    private let subtitlePolicy: SubtitlePolicyModel
    private let audioPolicy: AudioPolicyModel
    private let theme: ThemeSettingsModel
    private let nightShift: NightShiftSettingsModel
    private let homeVisibility: HomeLibraryVisibilityModel
    private let diagnostics: DiagnosticsSettingsModel
    private let crashReporting: CrashReportingSettingsModel
    private let crashReportingConfigured: Bool
    private let trakt: TraktService
    private let simkl: SimklService
    private let anilist: AniListService
    private let mal: MALService
    private let lastfm: LastFmService
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
        audioPolicy: AudioPolicyModel,
        theme: ThemeSettingsModel,
        nightShift: NightShiftSettingsModel,
        homeVisibility: HomeLibraryVisibilityModel,
        diagnostics: DiagnosticsSettingsModel,
        crashReporting: CrashReportingSettingsModel,
        crashReportingConfigured: Bool,
        trakt: TraktService,
        simkl: SimklService,
        anilist: AniListService,
        mal: MALService,
        lastfm: LastFmService,
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
        self.audioPolicy = audioPolicy
        self.theme = theme
        self.nightShift = nightShift
        self.homeVisibility = homeVisibility
        self.diagnostics = diagnostics
        self.crashReporting = crashReporting
        self.crashReportingConfigured = crashReportingConfigured
        self.trakt = trakt
        self.simkl = simkl
        self.anilist = anilist
        self.mal = mal
        self.lastfm = lastfm
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
                    // Device-shared settings come FIRST: servers + profile
                    // management belong to the whole Apple TV, not to you.
                    // Leading with the compact card makes the global scope
                    // obvious and keeps it visible without scrolling past the
                    // taller profile card.
                    thisAppleTVSection

                    // Then the active profile's own container: switching
                    // profiles swaps everything inside it at once, and its
                    // header makes clear these settings save on THIS profile.
                    profileContainer

                    // About + Attributions + Sign Out render INLINE at the
                    // bottom of the main page (no drill-down for About). Only
                    // Attributions & Licensing pushes one level deeper.
                    aboutAndSignOut
                }
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
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
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                editingProfile: profile,
                canDelete: profile.id != profiles.first?.id,
                photoSourceAccounts: accounts,
                plexHomeUsersFetcher: plexHomeUsersFetcher,
                onSave: { draft in
                    onSaveProfile(draft)
                    editingProfile = nil
                },
                onDelete: {
                    onDeleteProfile(profile.id)
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
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

    /// Rows nested inside the profile container — the settings this profile
    /// actually *owns*: identity + presentation only. Order: personal per-server
    /// settings first ("Your Libraries" — who you watch as + what shows on Home),
    /// then presentation (Appearance, Night Shift, Playback, Spoilers), then
    /// Trackers. Server sign-ins AND profile management (the roster) are
    /// intentionally NOT here — they're device-shared (see
    /// `thisAppleTVSection`). Each row pushes its own detail page via the root
    /// NavigationStack.
    @ViewBuilder
    private var profileOwnedRows: some View {
        // Inter-row spacing replaces the previous dividers: it lets the
        // contained focus lift breathe without crossing into a neighbor row
        // or sitting on top of a divider line.
        VStack(spacing: 14) {
            // Per-profile "Your Libraries": who you watch as + what shows on THIS
            // profile's Home. The personal mirror of This Apple TV › Servers.
            // Its second line glances the household's server sign-ins.
            navRow("Your Libraries", icon: "rectangle.stack",
                   value: nil,
                   route: .myLibraries) {
                signedInStrip
            }
            navRow("Appearance", icon: "paintpalette",
                   value: nil,
                   route: .appearance)
            navRow("Circadian Mode", icon: "moon.stars",
                   value: nil,
                   route: .nightShift) {
                Text("Warms the display at night to help you sleep")
                    .font(.footnote)
                    .settingsRowSecondary()
                    .lineLimit(2)
            }
            navRow("Playback", icon: "play.rectangle",
                   value: nil,
                   route: .playback)
            navRow("Spoilers", icon: "eye.slash",
                   value: nil,
                   route: .spoilers)
            navRow("Trackers — Trakt, Simkl, AniList, MyAnimeList, Last.fm", icon: "link",
                   value: nil,
                   route: .integrations)
        }
    }

    /// The **This Apple TV** container: everything shared by everyone on the
    /// device — server sign-ins (shared Keychain via `AccountStore`) and profile
    /// management (the roster; the launch picker lives one level in, on the
    /// Profiles screen). It leads the page so the global
    /// scope is obvious and rhymes visually with the profile card below. Nothing
    /// here belongs to a single profile; a profile only picks which of these
    /// servers it watches (see Profile › Your Libraries).
    @ViewBuilder
    private var thisAppleTVSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Device "identity on top": an Apple-TV glyph + name + scope note,
            // mirroring the profile card's avatar header.
            HStack(spacing: 20) {
                Image(systemName: "appletv")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.identityAvatarSize, height: Self.identityAvatarSize)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text("This Apple TV")
                        .font(Self.identityTitleFont)
                    Text("Servers and profiles, shared by everyone here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(28)

            Divider().padding(.horizontal, 28)

            VStack(spacing: 14) {
                // Shared server sign-ins (the household's full inventory). The
                // list screen opens with a prominent Add Server button.
                navRow("Servers", icon: "externaldrive.connected.to.line.below",
                       value: householdServersSummary,
                       route: .servers)

                // Profile roster management is a device concern (who exists on
                // this Apple TV), not a per-profile one — so it lives here.
                // "Ask on startup" (the launch picker) lives inside Profiles.
                if profilesEnabled {
                    navRow("Profiles", icon: "person.2",
                           value: "\(profiles.count)",
                           route: .profile)
                } else {
                    enableProfilesRow
                }
            }
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

            // Help & Diagnostics: report a problem (GitHub-issue QR) + the
            // playback diagnostics overlay toggle + recent redacted activity.
            navRow("Help & Diagnostics", icon: "ladybug",
                   value: nil,
                   route: .help)

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
        case .myLibraries:
            MyLibrariesDetailView(context: context)
        case .appearance:
            AppearanceDetailView(theme: theme)
        case .nightShift:
            NightShiftDetailView(model: nightShift)
        case .playback:
            PlaybackDetailView(playback: playback, captions: captions, subtitlePolicy: subtitlePolicy, audioPolicy: audioPolicy)
        case .spoilers:
            SpoilersDetailView(spoilers: spoilers)
        case .integrations:
            IntegrationsDetailView(trakt: trakt, simkl: simkl, anilist: anilist, mal: mal, lastfm: lastfm, playback: playback, serverCount: activeProfileServerCount)
        case .attributions:
            AttributionsDetailView()
        case .help:
            HelpDiagnosticsDetailView(
                appVersion: appVersion,
                appBuild: appBuild,
                repoURL: repoURL,
                accounts: accounts,
                diagnostics: diagnostics,
                crashReporting: crashReporting,
                crashReportingConfigured: crashReportingConfigured
            )
        case .recentActivity:
            RecentActivityDetailView()
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
            HStack(spacing: 20) {
                ProfileAvatarView(profile: activeProfile, size: Self.identityAvatarSize)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(activeProfile.name)
                        .font(Self.identityTitleFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Settings below are saved on this profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        editingProfile = activeProfile
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(action: onSwitchProfile) {
                        Text("Switch Profile")
                    }
                }
            }
        }
        .padding(28)
    }

    /// Compact, read-only glance of the household's server sign-ins, rendered as
    /// the SECOND line of the "Your Libraries" row. The row title labels it, so no
    /// caption is needed here. Uses `.settingsRowSecondary()` so it inverts with
    /// the row on focus. Capped to three entries with a trailing "+N more" so a
    /// busy household stays on one line.
    @ViewBuilder
    private var signedInStrip: some View {
        if !accounts.isEmpty {
            HStack(alignment: .center, spacing: 8) {
                let visible = Array(accounts.prefix(3))
                let overflow = max(0, accounts.count - visible.count)
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, account in
                    if idx > 0 {
                        Text("·")
                            .font(.subheadline.weight(.bold))
                            .settingsRowSecondary()
                    }
                    HStack(spacing: 6) {
                        ProviderIcon(provider: account.server.provider, size: 24)
                        AccountAvatar(name: account.userName, imageURL: account.avatarURL, size: 20)
                        Text(signedInLabel(for: account))
                            .font(.footnote.weight(.medium))
                            .settingsRowSecondary()
                            .lineLimit(1)
                    }
                }
                if overflow > 0 {
                    Text("· +\(overflow) more")
                        .font(.footnote)
                        .settingsRowSecondary()
                }
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

    /// Global summary for the This Apple TV › Servers row: how many distinct
    /// servers the household is signed in to (device scope, not profile).
    private var householdServersSummary: String {
        if accounts.isEmpty { return "Add a server" }
        // Row already says "Servers", so show a bare count (no repeated noun).
        return "\(Set(accounts.map { $0.server.id }).count)"
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
        navRow(title, icon: icon, value: value, route: route) { EmptyView() }
    }

    /// Two-line variant: `secondary` renders a second line beneath the title
    /// (a status strip, helper text…). Shares the exact row body + focus style
    /// as the one-line rows via ``SettingsRowLabel``.
    @ViewBuilder
    private func navRow<Secondary: View>(
        _ title: String,
        icon: String,
        value: String?,
        route: SettingsRoute,
        @ViewBuilder secondary: () -> Secondary
    ) -> some View {
        NavigationLink(value: route) {
            SettingsRowLabel(icon: icon, title: title, secondary: secondary) {
                HStack(spacing: 16) {
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
            }
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }
}

#endif
