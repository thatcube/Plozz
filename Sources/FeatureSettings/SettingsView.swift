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
        case playback
        case captions
        case spoilers
        case integrations
        case about
    }

    @State private var path: [SettingsRoute] = []

    private let captions: CaptionSettingsModel
    private let spoilers: SpoilerSettingsModel
    private let theme: ThemeSettingsModel
    private let diagnostics: DiagnosticsSettingsModel
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

    public init(
        captions: CaptionSettingsModel,
        spoilers: SpoilerSettingsModel,
        theme: ThemeSettingsModel,
        diagnostics: DiagnosticsSettingsModel,
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
        onSignOutAll: @escaping () -> Void
    ) {
        self.captions = captions
        self.spoilers = spoilers
        self.theme = theme
        self.diagnostics = diagnostics
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
    }

    private var context: SettingsContext {
        SettingsContext(
            captions: captions,
            spoilers: spoilers,
            theme: theme,
            diagnostics: diagnostics,
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
            onSignOutAll: onSignOutAll
        )
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Switching profiles swaps every setting on this screen
                    // (theme, captions, spoilers, Trakt, Home, server
                    // inclusion). Make that explicit at the very top.
                    if profilesEnabled {
                        activeProfileHeader
                    }

                    SettingsPanel {
                        VStack(spacing: 0) {
                            if profilesEnabled {
                                navRow("Profile", icon: "person.crop.circle",
                                       value: activeProfile.name,
                                       route: .profile)
                                Divider()
                            } else {
                                enableProfilesRow
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
                            navRow("Playback", icon: "play.rectangle",
                                   value: diagnostics.settings.isEnabled ? "Diagnostics on" : nil,
                                   route: .playback)
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
                            Divider()
                            navRow("About & Sign Out", icon: "info.circle",
                                   value: nil,
                                   route: .about)
                        }
                    }
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
        case .playback:
            PlaybackDetailView(diagnostics: diagnostics)
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
        }
    }

    // MARK: - Header (active profile)

    private var activeProfileHeader: some View {
        SettingsPanel(
            footer: "Switching profiles swaps every preference on this screen — theme, captions, spoilers, Trakt account, and which servers/libraries are included. Plozz remembers the last profile picked on this Apple TV user."
        ) {
            HStack(spacing: 20) {
                Image(systemName: activeProfile.avatarSymbol)
                    .font(.largeTitle)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.accentColor.opacity(0.25)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeProfile.name).font(.title3.weight(.semibold))
                    Text(profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onSwitchProfile) {
                    Label("Switch Profile", systemImage: "person.2.circle")
                }
            }
        }
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
