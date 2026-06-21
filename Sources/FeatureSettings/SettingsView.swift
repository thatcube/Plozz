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
    @State private var diagnostics: DiagnosticsSettingsModel
    private let accounts: [Account]
    private let activeAccountID: String?
    private let appVersion: String
    private let appBuild: String
    private let repoURL: String
    private let onAddAccount: () -> Void
    private let onRemoveAccount: (Account) -> Void
    private let onSignOutAll: () -> Void

    public init(
        captions: CaptionSettingsModel,
        spoilers: SpoilerSettingsModel,
        diagnostics: DiagnosticsSettingsModel,
        accounts: [Account],
        activeAccountID: String?,
        appVersion: String,
        appBuild: String,
        repoURL: String,
        onAddAccount: @escaping () -> Void,
        onRemoveAccount: @escaping (Account) -> Void,
        onSignOutAll: @escaping () -> Void
    ) {
        _captions = State(initialValue: captions)
        _spoilers = State(initialValue: spoilers)
        _diagnostics = State(initialValue: diagnostics)
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.repoURL = repoURL
        self.onAddAccount = onAddAccount
        self.onRemoveAccount = onRemoveAccount
        self.onSignOutAll = onSignOutAll
    }

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

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
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                    Button(action: onAddAccount) {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                } header: {
                    Text(accounts.count == 1 ? "Account" : "Accounts")
                } footer: {
                    Text("Add another Jellyfin server to switch between libraries.")
                }

                Section("Captions") {
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
