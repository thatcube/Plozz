#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings: account management, caption customization, spoiler protection, and
/// sign out.
///
/// Uses only tvOS-supported controls — `Toggle`, `Picker`, `Button` — since
/// `Slider` isn't available on tvOS. Caption/spoiler changes apply immediately
/// and persist via their models. The Accounts section lists every signed-in
/// account and lets the user add another server or remove one.
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

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    /// A short, common-language list for the subtitle language picker. Codes are
    /// 2-letter ISO-639-1; the provider normalises to the server's expected form.
    static let subtitleLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
        ("no", "Norwegian"), ("da", "Danish"), ("fi", "Finnish"), ("pl", "Polish"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ("ar", "Arabic"), ("tr", "Turkish")
    ]

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
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: activeProfile.avatarSymbol)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.accentColor.opacity(0.25)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeProfile.name).font(.headline)
                            Text(profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Button(action: onSwitchProfile) {
                        Label("Switch Profile", systemImage: "person.2.circle")
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Each profile keeps its own theme, spoiler, caption, and account selections.")
                }

                Section {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                    Button(action: onAddAccount) {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                } header: {
                    Text(accounts.count == 1 ? "Account" : "Accounts")
                } footer: {
                    Text("Add another Jellyfin or Plex server to combine their libraries on Home.")
                }

                homeLibrariesSection

                Section {
                    ForEach(AppTheme.allCases) { option in
                        Button {
                            theme.theme = option
                        } label: {
                            HStack {
                                Label(option.displayName, systemImage: option.symbolName)
                                Spacer()
                                if theme.theme == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Choose how Plozz looks. System follows your Apple TV's appearance; OLED uses a pure-black background.")
                }

                Section("Captions") {
                    Toggle("Automatically download subtitles", isOn: $captions.settings.autoDownloadSubtitles)

                    Picker("Show subtitles", selection: $captions.settings.subtitleMode) {
                        ForEach(CaptionSettings.SubtitleMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("Subtitle language", selection: $captions.settings.preferredSubtitleLanguage) {
                        Text("Device Default").tag(String?.none)
                        ForEach(Self.subtitleLanguages, id: \.code) { language in
                            Text(language.name).tag(String?.some(language.code))
                        }
                    }

                    Toggle("Use system caption style", isOn: $captions.settings.followsSystemStyle)

                    if !captions.settings.followsSystemStyle {
                        Picker("Text size", selection: $captions.settings.fontScale) {
                            ForEach(fontScales, id: \.self) { scale in
                                Text("\(Int(scale * 100))%").tag(scale)
                            }
                        }

                        Picker("Text color", selection: $captions.settings.textColor) {
                            ForEach(CaptionSettings.RGBAColor.presets, id: \.name) { preset in
                                Text(preset.name).tag(preset.color)
                            }
                        }

                        Picker("Background", selection: $captions.settings.backgroundColor.alpha) {
                            ForEach(backgroundOpacities, id: \.self) { opacity in
                                Text(opacity == 0 ? "Off" : "\(Int(opacity * 100))%").tag(opacity)
                            }
                        }

                        Picker("Edge style", selection: $captions.settings.edgeStyle) {
                            ForEach(CaptionSettings.EdgeStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }

                        CaptionPreview(settings: captions.settings)
                    }
                }

                Section("Spoiler Protection") {
                    Toggle("Hide spoilers for unwatched episodes", isOn: $spoilers.settings.isEnabled)

                    if spoilers.settings.isEnabled {
                        ForEach(SpoilerSettings.Mode.allCases, id: \.self) { mode in
                            Button {
                                spoilers.settings.mode = mode
                            } label: {
                                HStack {
                                    Text(mode.displayName)
                                    Spacer()
                                    if spoilers.settings.mode == mode {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }

                        Text(spoilerModeExplanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !accounts.isEmpty {
                    Section {
                        Button(role: .destructive, action: onSignOutAll) {
                            Label("Sign Out of All Accounts", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }

                Section {
                    Toggle("Show playback diagnostics", isOn: $diagnostics.settings.isEnabled)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Overlays live stream details (resolution, bitrate, codec, HDR, buffer, dropped frames) on top of the player.")
                }

                Section("About") {
                    SettingsAboutSection(
                        version: appVersion,
                        build: appBuild,
                        repoURL: repoURL
                    )
                }
            }
            .navigationTitle("Settings")
            .task { await reloadLibraries() }
        }
    }

    /// The customizable "Home Libraries" checklist: every discovered library,
    /// grouped by account/provider, with an opt-out toggle that controls Home
    /// visibility. Toggling persists immediately and updates Home live.
    @ViewBuilder
    private var homeLibrariesSection: some View {
        switch discoveredLibraries {
        case .idle, .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Discovering libraries…")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Home Libraries")
            }
        case .empty:
            Section {
                Text("No libraries found on your servers.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Home Libraries")
            }
        case .failed:
            Section {
                Text("Couldn't load your libraries.")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await reloadLibraries() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Home Libraries")
            }
        case let .loaded(libraries):
            Section {
                ForEach(groupedLibraries(libraries), id: \.id) { group in
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
            } header: {
                Text("Home Libraries")
            } footer: {
                Text("Choose which libraries appear on your Home screen. Newly added libraries appear automatically.")
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

    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.userName).font(.headline)
                    Text(account.server.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(account.server.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if account.id == activeAccountID {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }
            Button(role: .destructive) {
                onRemoveAccount(account)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Live preview of how captions will look with the current settings.
private struct CaptionPreview: View {
    let settings: CaptionSettings

    var body: some View {
        VStack {
            Spacer()
            Text("The quick brown fox")
                .font(.system(size: 32 * settings.fontScale))
                .foregroundStyle(settings.textColor.swiftUIColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(settings.backgroundColor.swiftUIColor)
                .shadow(radius: settings.edgeStyle == .dropShadow ? 4 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
        .padding(.vertical, 8)
    }
}

extension CaptionSettings.RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

#endif
