#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings: account management, appearance, caption customization, spoiler
/// protection, playback diagnostics, and sign out.
///
/// Laid out in the Twozz style — distinct **sections**, each a panel, with
/// selectable options presented as a **horizontal row of focusable cards**
/// (`OptionCardRow`) rather than one long vertical list of pickers. This strays
/// slightly from native tvOS Settings but scales far better as options grow.
/// Caption controls are factored into the reusable `CaptionSettingsCard`
/// (CoreUI) so the player can surface the same UI mid-playback. The whole screen
/// is a `ScrollView` of focusable content, which also fixes the previously
/// unreachable (and therefore unreadable) About section on tvOS.
public struct SettingsView: View {
    @State private var captions: CaptionSettingsModel
    @State private var spoilers: SpoilerSettingsModel
    @State private var theme: ThemeSettingsModel
    @State private var diagnostics: DiagnosticsSettingsModel
    @State private var homeVisibility: HomeLibraryVisibilityModel
    private let discoveredLibraries: LoadState<[AggregatedLibrary]>
    private let reloadLibraries: () async -> Void
    private let accounts: [Account]
    private let activeAccountID: String?
    private let profiles: [Profile]
    private let activeProfile: Profile
    private let appVersion: String
    private let appBuild: String
    private let repoURL: String
    private let onAddAccount: () -> Void
    private let onRemoveAccount: (Account) -> Void
    private let onSignOutAll: () -> Void
    private let onSwitchProfile: () -> Void

    public init(
        captions: CaptionSettingsModel,
        spoilers: SpoilerSettingsModel,
        theme: ThemeSettingsModel,
        diagnostics: DiagnosticsSettingsModel,
        homeVisibility: HomeLibraryVisibilityModel,
        discoveredLibraries: LoadState<[AggregatedLibrary]>,
        reloadLibraries: @escaping () async -> Void,
        accounts: [Account],
        activeAccountID: String?,
        profiles: [Profile],
        activeProfile: Profile,
        appVersion: String,
        appBuild: String,
        repoURL: String,
        onAddAccount: @escaping () -> Void,
        onRemoveAccount: @escaping (Account) -> Void,
        onSignOutAll: @escaping () -> Void,
        onSwitchProfile: @escaping () -> Void
    ) {
        _captions = State(initialValue: captions)
        _spoilers = State(initialValue: spoilers)
        _theme = State(initialValue: theme)
        _diagnostics = State(initialValue: diagnostics)
        _homeVisibility = State(initialValue: homeVisibility)
        self.discoveredLibraries = discoveredLibraries
        self.reloadLibraries = reloadLibraries
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.repoURL = repoURL
        self.onAddAccount = onAddAccount
        self.onRemoveAccount = onRemoveAccount
        self.onSignOutAll = onSignOutAll
        self.onSwitchProfile = onSwitchProfile
    }

    private var spoilerModeExplanation: String {
        switch spoilers.settings.mode {
        case .blur:
            return "Episode thumbnails are blurred until watched. Titles and descriptions stay hidden until you finish the episode."
        case .placeholder:
            return "Episode thumbnails are replaced with generic series art and the episode number, so no real frame is ever shown. Titles and descriptions stay hidden until you finish the episode."
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    profilePanel
                    accountsPanel
                    homeLibrariesPanel
                    appearancePanel
                    captionsPanel
                    spoilerPanel
                    playbackPanel
                    if !accounts.isEmpty { signOutPanel }
                    aboutPanel
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 40)
            }
            // Never clip a focused control's lift, shadow or border.
            .scrollClipDisabled()
            .task { await reloadLibraries() }
        }
    }

    // MARK: - Profile

    private var profilePanel: some View {
        SettingsPanel(
            title: "Profile",
            footer: "Each profile keeps its own theme, spoiler, caption, and account selections."
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

    // MARK: - Accounts

    private var accountsPanel: some View {
        SettingsPanel(
            title: accounts.count == 1 ? "Account" : "Accounts",
            footer: "Add another Jellyfin or Plex server to combine their libraries on Home."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(accounts) { account in
                    accountRow(account)
                }
                Button(action: onAddAccount) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Label("Add Account", systemImage: "plus.circle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusSection()
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.userName).font(.headline)
                HStack(spacing: 6) {
                    Text(account.server.name)
                    Text("·")
                    Text(account.server.provider.displayName)
                    Text("·")
                    Text(account.server.baseURL.host ?? account.server.baseURL.absoluteString)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if account.id == activeAccountID {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            }
            Button(role: .destructive) {
                onRemoveAccount(account)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove \(account.userName)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    // MARK: - Home libraries

    /// The customizable "Home Libraries" checklist: every discovered library,
    /// grouped by account/provider, with an opt-out toggle that controls Home
    /// visibility. Toggling persists immediately and updates Home live.
    @ViewBuilder
    private var homeLibrariesPanel: some View {
        switch discoveredLibraries {
        case .idle, .loading:
            SettingsPanel(title: "Home Libraries") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Discovering libraries…")
                        .foregroundStyle(.secondary)
                }
            }
        case .empty:
            SettingsPanel(title: "Home Libraries") {
                Text("No libraries found on your servers.")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            SettingsPanel(title: "Home Libraries") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Couldn't load your libraries.")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await reloadLibraries() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
            }
        case let .loaded(libraries):
            SettingsPanel(
                title: "Home Libraries",
                footer: "Choose which libraries appear on your Home screen. Newly added libraries appear automatically."
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groupedLibraries(libraries), id: \.id) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.header)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(group.libraries) { aggregated in
                                Toggle(aggregated.library.title, isOn: Binding(
                                    get: { homeVisibility.isVisible(aggregated.key) },
                                    set: { homeVisibility.setVisible($0, for: aggregated.key) }
                                ))
                            }
                        }
                    }
                }
            }
        }
    }

    private struct LibraryGroup: Identifiable {
        let id: String
        let header: String
        let libraries: [AggregatedLibrary]
    }

    /// Groups discovered libraries by their owning account, preserving discovery
    /// order, with a "user · server (provider)" header per group.
    private func groupedLibraries(_ libraries: [AggregatedLibrary]) -> [LibraryGroup] {
        var order: [String] = []
        var groups: [String: [AggregatedLibrary]] = [:]
        for library in libraries {
            if groups[library.accountID] == nil { order.append(library.accountID) }
            groups[library.accountID, default: []].append(library)
        }
        return order.compactMap { accountID in
            guard let libs = groups[accountID], let first = libs.first else { return nil }
            let header = "\(first.accountName) · \(first.serverName) (\(first.providerKind.displayName))"
            return LibraryGroup(id: accountID, header: header, libraries: libs)
        }
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        SettingsPanel(
            title: "Appearance",
            footer: "Choose how Plozz looks. System follows your Apple TV's appearance; OLED uses a pure-black background."
        ) {
            OptionCardRow(options: AppTheme.allCases, selection: themeBinding) { option in
                VStack(spacing: 12) {
                    Image(systemName: option.symbolName)
                        .font(.largeTitle)
                    Text(option.displayName)
                        .font(.headline)
                }
            }
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }

    // MARK: - Captions

    private var captionsPanel: some View {
        SettingsPanel(
            title: "Captions",
            footer: "These caption settings are also available from the player while you watch."
        ) {
            CaptionSettingsCard(settings: $captions.settings)
        }
    }

    // MARK: - Spoilers

    private var spoilerPanel: some View {
        SettingsPanel(title: "Spoiler Protection") {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Hide spoilers for unwatched episodes", isOn: $spoilers.settings.isEnabled)

                if spoilers.settings.isEnabled {
                    OptionCardRow(
                        options: SpoilerSettings.Mode.allCases,
                        selection: $spoilers.settings.mode
                    ) { mode in
                        Text(mode.displayName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }

                    Text(spoilerModeExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Playback

    private var playbackPanel: some View {
        SettingsPanel(
            title: "Playback",
            footer: "Overlays live stream details (resolution, bitrate, codec, HDR, buffer, dropped frames) on top of the player."
        ) {
            Toggle("Show playback diagnostics", isOn: $diagnostics.settings.isEnabled)
        }
    }

    // MARK: - Sign out

    private var signOutPanel: some View {
        SettingsPanel(title: "Sign Out") {
            Button(role: .destructive, action: onSignOutAll) {
                Label("Sign Out of All Accounts", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        SettingsPanel(title: "About") {
            SettingsAboutSection(
                version: appVersion,
                build: appBuild,
                repoURL: repoURL
            )
        }
    }
}

/// A titled settings section rendered as a translucent panel. Used to break the
/// screen into clear, scalable sections in the Twozz style.
private struct SettingsPanel<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline.weight(.semibold))
            content
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
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

#endif
