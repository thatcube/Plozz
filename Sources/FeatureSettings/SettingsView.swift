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
    private enum FocusTarget: Hashable {
        case switchProfile
    }

    @FocusState private var focusedControl: FocusTarget?
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
            .defaultFocus($focusedControl, .switchProfile)
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
                .focused($focusedControl, equals: .switchProfile)
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
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusSection()
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 16) {
            accountAvatar(name: account.userName, imageURL: resolvedAvatarURL(for: account), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.userName).font(.headline)
                HStack(spacing: 6) {
                    Text(account.server.name)
                    Text("·")
                    providerLabel(account.server.provider)
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
                            HStack(spacing: 10) {
                                accountAvatar(name: group.accountName, imageURL: group.accountAvatarURL, size: 30)
                                Text("\(group.accountName) · \(group.serverName)")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                providerLabel(group.providerKind)
                            }
                            ForEach(group.libraries) { aggregated in
                                Toggle(isOn: Binding(
                                    get: { homeVisibility.isVisible(aggregated.key) },
                                    set: { homeVisibility.setVisible($0, for: aggregated.key) }
                                )) {
                                    HStack(spacing: 8) {
                                        providerIcon(aggregated.providerKind, size: 16)
                                        Text(aggregated.library.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct LibraryGroup: Identifiable {
        let id: String
        let accountName: String
        let serverName: String
        let providerKind: ProviderKind
        let accountAvatarURL: URL?
        let libraries: [AggregatedLibrary]
    }

    /// Groups discovered libraries by their owning account, preserving discovery
    /// order, with a "user · server (provider)" header per group.
    private func groupedLibraries(_ libraries: [AggregatedLibrary]) -> [LibraryGroup] {
        let accountByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var order: [String] = []
        var groups: [String: [AggregatedLibrary]] = [:]
        for library in libraries {
            if groups[library.accountID] == nil { order.append(library.accountID) }
            groups[library.accountID, default: []].append(library)
        }
        return order.compactMap { accountID in
            guard let libs = groups[accountID], let first = libs.first else { return nil }
            return LibraryGroup(
                id: accountID,
                accountName: first.accountName,
                serverName: first.serverName,
                providerKind: first.providerKind,
                accountAvatarURL: accountByID[accountID].flatMap(resolvedAvatarURL),
                libraries: libs
            )
        }
    }

    private func resolvedAvatarURL(for account: Account) -> URL? {
        if let avatarURL = account.avatarURL {
            return avatarURL
        }
        guard account.server.provider == .jellyfin,
              var components = URLComponents(url: account.server.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/Users/\(account.userID)/Images/Primary"
        return components.url
    }

    @ViewBuilder
    private func providerLabel(_ provider: ProviderKind) -> some View {
        HStack(spacing: 4) {
            providerIcon(provider, size: 14)
            Text(provider.displayName)
        }
        .fixedSize()
    }

    private func providerIcon(_ provider: ProviderKind, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(providerTint(provider).opacity(0.18))
            Image(systemName: provider == .jellyfin ? "drop.fill" : "chevron.forward")
                .font(.system(size: provider == .jellyfin ? size * 0.58 : size * 0.52, weight: .bold))
                .foregroundStyle(providerTint(provider))
        }
        .frame(width: size, height: size)
    }

    private func providerTint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin:
            return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .plex:
            return Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
        }
    }

    private func accountAvatar(name: String, imageURL: URL?, size: CGFloat) -> some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        avatarPlaceholder(name: name)
                    @unknown default:
                        avatarPlaceholder(name: name)
                    }
                }
            } else {
                avatarPlaceholder(name: name)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private func avatarPlaceholder(name: String) -> some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.10))
            Text(String(name.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        SettingsPanel(title: "Appearance") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(AppTheme.allCases) { option in
                        Button {
                            theme.theme = option
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: option.symbolName)
                                Text(option.displayName)
                                if theme.theme == option {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .font(.headline)
                            .padding(.horizontal, 4)
                        }
                        .plozzGlassPillButton(isSelected: theme.theme == option)
                        .accessibilityValue(theme.theme == option ? "Selected" : "")
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
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

                Divider()

                Toggle("Hide ratings until watched", isOn: $spoilers.settings.hideRatingsUntilWatched)

                Text("Keeps IMDb, Rotten Tomatoes and other scores hidden on a movie or episode until you've finished it, so the ratings don't bias you beforehand. They appear once it's marked watched.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
