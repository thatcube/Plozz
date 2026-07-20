#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI
import UIKit

struct PlozziOSSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingAddServer = false
    @State private var addServerPresentationColorScheme: ColorScheme = .dark
    let appModel: PlozziOSAppModel
    let onClose: () -> Void
    let systemColorScheme: ColorScheme

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PlozziOSSettingsSplitView(
                    appModel: appModel,
                    onAddServer: showAddServer,
                    onClose: onClose
                )
            } else {
                NavigationStack {
                    PlozziOSSettingsCompactMenu(
                        appModel: appModel,
                        onAddServer: showAddServer
                    )
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground(palette: palette) }
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .tint(palette.primaryText)
        .modifier(
            PlozziOSSettingsListAppearance(
                usesPureBlack: appModel.settings.theme.theme == .pureBlack
            )
        )
        .sheet(
            isPresented: $showingAddServer,
            onDismiss: appModel.finishManagedServerPresentation
        ) {
            AddServerView(appModel: appModel)
                .preferredColorScheme(addServerPresentationColorScheme)
                .presentationSizing(.page)
        }
        .sheet(item: plexUserSelectionBinding) { selection in
            PlozziOSPlexUserSelectionView(
                selection: selection,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        .sheet(item: plexPINBinding) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
        .sheet(item: librarySelectionBinding) { selection in
            PlozziOSLibrarySelectionView(
                accounts: appModel.accountsProviders.resolvedAccounts(
                    withIDs: selection.accountIDs
                ),
                visibility: appModel.settings.homeVisibility,
                onContinue: appModel.completeLibrarySelection
            )
            .preferredColorScheme(addServerPresentationColorScheme)
        }
    }

    private func showAddServer() {
        addServerPresentationColorScheme = palette.isLight ? .light : .dark
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexUserSelection },
            set: { selection in
                if selection == nil {
                    appModel.cancelPlexUserSelectionDuringOnboarding()
                }
            }
        )
    }

    private var plexPINBinding:
        Binding<PlexHomeUsersModel.PlexPINRequest?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexPINRequest },
            set: { request in
                if request == nil {
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: { appModel.pendingLibrarySelection },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    private var palette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }
}

private struct PlozziOSSettingsListAppearance: ViewModifier {
    let usesPureBlack: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesPureBlack {
            content.listStyle(.plain)
        } else {
            content
        }
    }
}

private enum PlozziOSSettingsDestination: Hashable {
    case profiles
    case requests
    case servers
    case myLibraries
    case trackers
    case appearance
    case home
    case playback
    case downloads
    case subtitles
    case spoilers
    case nightShift
    case diagnostics
    case attributions
    case about
}

var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
}

private var deviceSettingsTitle: String {
    "On This \(deviceName)"
}

private struct PlozziOSSettingsSplitView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    let onClose: () -> Void
    @State private var selection: PlozziOSSettingsDestination? = .profiles
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var confirmSignOutAll = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ScrollView {
                LazyVStack(spacing: 18) {
                    SettingsSectionGroup(deviceSettingsTitle) {
                        Button {
                            selection = .profiles
                        } label: {
                            Label(
                                "Profiles",
                                systemImage: "person.2"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        settingsRow(
                            .requests,
                            title: "Seerr",
                            systemImage: "sparkles.tv"
                        )
                        settingsRow(
                            .servers,
                            title: "Servers",
                            systemImage: "externaldrive.connected.to.line.below"
                        )
                        settingsRow(
                            .downloads,
                            title: "Downloads",
                            systemImage: "arrow.down.circle"
                        )
                    } footer: {
                        Text("Shared across every profile on this \(deviceName).")
                    }

                    SettingsSectionGroup("This Profile") {
                        settingsRow(
                            .myLibraries,
                            title: SettingsCopy.libraries,
                            systemImage: "rectangle.stack"
                        )
                        settingsRow(.trackers, title: "Trackers", systemImage: "link")
                        settingsRow(.appearance, title: "Appearance", systemImage: "paintpalette")
                        settingsRow(.home, title: "Customize Home", systemImage: "house")
                        settingsRow(.playback, title: "Playback", systemImage: "play.rectangle")
                        settingsRow(.subtitles, title: "Subtitles", systemImage: "captions.bubble")
                        settingsRow(.spoilers, title: "Spoilers", systemImage: "eye.slash")
                        settingsRow(.nightShift, title: "Circadian Mode", systemImage: "moon.stars.fill")
                    } footer: {
                        Text("Saved for \(appModel.profiles.activeProfile.name).")
                    }

                    SettingsSectionGroup("Support") {
                        settingsRow(.diagnostics, title: "Help & Diagnostics", systemImage: "ladybug")
                        settingsRow(.attributions, title: "Attributions & Licensing", systemImage: "doc.text.magnifyingglass")
                        settingsRow(.about, title: "About", systemImage: "info.circle")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(
                min: 300,
                ideal: 320,
                max: 360
            )
            .toolbar(removing: .sidebarToggle)
            .scrollContentBackground(.hidden)
            .background { AppBackground(palette: palette) }
        } detail: {
            NavigationStack {
                ZStack {
                    AppBackground(palette: palette)
                    Group {
                        settingsDetail
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .plozziOSSettingsSurface()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(selection)
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose)
            }
        }
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all {
                columnVisibility = .all
            }
        }
    }

    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selection ?? .profiles {
        case .profiles:
            PlozziOSProfilesView(appModel: appModel)
        case .requests:
            PlozziOSSeerrSettingsView(appModel: appModel)
        case .servers:
            PlozziOSServersSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        case .myLibraries:
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        case .trackers:
            PlozziOSTrackerSettingsView(appModel: appModel)
        case .appearance:
            PlozziOSAppearanceSettingsView(
                theme: appModel.settings.theme,
                transparency: appModel.settings.transparency,
                cardStyle: appModel.settings.cardStyle,
                density: appModel.settings.density,
                watchIndicator: appModel.settings.watchIndicator
            )
        case .home:
            PlozziOSHomeSettingsView(
                hero: appModel.settings.hero,
                visibility: appModel.settings.homeVisibility,
                accounts: appModel.accountsProviders.resolvedActiveAccounts,
                seerConfigured: appModel.seerService.isConfigured
            )
        case .playback:
            PlozziOSPlaybackSettingsView(
                model: appModel.settings.playback,
                audioPolicy: appModel.settings.audioPolicy,
                heroBackground: appModel.settings.heroBackground,
                themeMusic: appModel.settings.themeMusic
            )
        case .downloads:
            PlozziOSDownloadSettingsView(model: appModel.downloads)
        case .subtitles:
            PlozziOSSubtitleSettingsView(
                behavior: appModel.settings.subtitleBehavior,
                policy: appModel.settings.subtitlePolicy,
                style: appModel.settings.subtitleStyle
            )
        case .spoilers:
            PlozziOSSpoilerSettingsView(model: appModel.settings.spoilers)
        case .nightShift:
            PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
        case .diagnostics:
            PlozziOSDiagnosticsSettingsView(
                appModel: appModel,
                model: appModel.settings.diagnostics,
                crashReporting: appModel.crashReporting
            )
        case .attributions:
            PlozziOSAttributionsView()
        case .about:
            PlozziOSAboutSettingsView(
                hasAccounts: !appModel.accounts.isEmpty,
                onSignOutAll: { confirmSignOutAll = true }
            )
        }
    }
}

private struct PlozziOSAboutSettingsView: View {
    let hasAccounts: Bool
    let onSignOutAll: () -> Void

    var body: some View {
        Form {
            SettingsSectionGroup("Plozz") {
                LabeledContent("Version") {
                    Text(
                        Bundle.main.infoDictionary?[
                            "CFBundleShortVersionString"
                        ] as? String ?? "—"
                    )
                }
                LabeledContent("Build") {
                    Text(
                        Bundle.main.infoDictionary?[
                            "CFBundleVersion"
                        ] as? String ?? "—"
                    )
                }
            }

            if hasAccounts {
                SettingsSectionGroup {
                    Button(
                        "Sign Out of All Accounts",
                        role: .destructive,
                        action: onSignOutAll
                    )
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("About")
    }
}

private struct PlozziOSSettingsCompactMenu: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var confirmSignOutAll = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                SettingsSectionGroup(deviceSettingsTitle) {
                NavigationLink {
                    PlozziOSProfilesView(appModel: appModel)
                } label: {
                    Label(
                        "Profiles",
                        systemImage: "person.2"
                    )
                }

                NavigationLink {
                    PlozziOSSeerrSettingsView(appModel: appModel)
                } label: {
                    Label("Seerr", systemImage: "sparkles.tv")
                }

                NavigationLink {
                    PlozziOSServersSettingsView(
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                } label: {
                    Label("Servers", systemImage: "externaldrive.connected.to.line.below")
                }
                NavigationLink {
                    PlozziOSDownloadSettingsView(model: appModel.downloads)
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Shared across every profile on this \(deviceName).")
            }

                SettingsSectionGroup("This Profile") {
                NavigationLink {
                    PlozziOSMyLibrariesSettingsView(
                        appModel: appModel,
                        onAddServer: onAddServer
                    )
                } label: {
                    Label(
                        SettingsCopy.libraries,
                        systemImage: "rectangle.stack"
                    )
                }
                NavigationLink {
                    PlozziOSTrackerSettingsView(appModel: appModel)
                } label: {
                    Label("Trackers", systemImage: "link")
                }
                NavigationLink {
                    PlozziOSAppearanceSettingsView(
                        theme: appModel.settings.theme,
                        transparency: appModel.settings.transparency,
                        cardStyle: appModel.settings.cardStyle,
                        density: appModel.settings.density,
                        watchIndicator: appModel.settings.watchIndicator
                    )
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    PlozziOSHomeSettingsView(
                        hero: appModel.settings.hero,
                        visibility: appModel.settings.homeVisibility,
                        accounts: appModel.accountsProviders.resolvedActiveAccounts,
                        seerConfigured: appModel.seerService.isConfigured
                    )
                } label: {
                    Label("Customize Home", systemImage: "house")
                }
                NavigationLink {
                    PlozziOSPlaybackSettingsView(
                        model: appModel.settings.playback,
                        audioPolicy: appModel.settings.audioPolicy,
                        heroBackground: appModel.settings.heroBackground,
                        themeMusic: appModel.settings.themeMusic
                    )
                } label: {
                    Label("Playback", systemImage: "play.rectangle")
                }
                NavigationLink {
                    PlozziOSSubtitleSettingsView(
                        behavior: appModel.settings.subtitleBehavior,
                        policy: appModel.settings.subtitlePolicy,
                        style: appModel.settings.subtitleStyle
                    )
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                NavigationLink {
                    PlozziOSSpoilerSettingsView(model: appModel.settings.spoilers)
                } label: {
                    Label("Spoilers", systemImage: "eye.slash")
                }
                NavigationLink {
                    PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
                } label: {
                    Label("Circadian Mode", systemImage: "moon.stars.fill")
                }
            } footer: {
                Text("Saved for \(appModel.profiles.activeProfile.name).")
            }

                SettingsSectionGroup("Support") {
                NavigationLink {
                    PlozziOSDiagnosticsSettingsView(
                        appModel: appModel,
                        model: appModel.settings.diagnostics,
                        crashReporting: appModel.crashReporting
                    )
                } label: {
                    Label("Help & Diagnostics", systemImage: "ladybug")
                }
                NavigationLink {
                    PlozziOSAttributionsView()
                } label: {
                    Label("Attributions & Licensing", systemImage: "doc.text.magnifyingglass")
                }
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                }
                if !appModel.accounts.isEmpty {
                    Button("Sign Out of All Accounts", role: .destructive) {
                        confirmSignOutAll = true
                    }
                }
            }

                if let accountError = appModel.accountError {
                    SettingsSectionGroup {
                        Label(accountError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .plozziOSSettingsSurface()
        .navigationTitle("Settings")
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
    }
}

private struct PlozziOSProfilesView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var showingAddProfile = false
    @State private var editingProfile: Profile?

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle(
                    "Enable Profiles",
                    isOn: Binding(
                        get: { appModel.profiles.profilesEnabled },
                        set: { enabled in
                            if enabled {
                                appModel.profiles.enableProfiles()
                            } else {
                                appModel.profiles.disableProfiles()
                            }
                        }
                    )
                )
                .disabled(appModel.profiles.profiles.count > 1)

                if appModel.profiles.profilesEnabled {
                    if appModel.profiles.profiles.count > 1 {
                        Picker(
                            "Current Profile",
                            selection: Binding(
                                get: { appModel.profiles.activeProfileID },
                                set: { appModel.selectProfile($0) }
                            )
                        ) {
                            ForEach(appModel.profiles.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                    }
                    Toggle(
                        "Ask Who’s Watching on Startup",
                        isOn: Binding(
                            get: {
                                appModel.profiles.askProfileOnStartup
                            },
                            set: {
                                appModel.profiles.setAskProfileOnStartup($0)
                            }
                        )
                    )
                }
            } footer: {
                if appModel.profiles.profiles.count > 1 {
                    Text("Profiles stay enabled while more than one household profile exists.")
                } else {
                    Text("Profiles keep Home, settings, watch history, and downloads personal.")
                }
            }

            SettingsSectionGroup("Who’s watching?") {
                ForEach(appModel.profiles.profiles) { profile in
                    Button {
                        editingProfile = profile
                    } label: {
                        HStack {
                            PlozziOSProfileAvatar(profile: profile, size: 34)
                            Text(profile.name)
                            Spacer()
                            if profile.id == appModel.profiles.activeProfileID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !appModel.profiles.isDefault(profile) {
                            Button("Delete", role: .destructive) {
                                appModel.removeProfile(profile.id)
                            }
                        }
                    }
                }
                Button("Add Profile", systemImage: "person.badge.plus") {
                    showingAddProfile = true
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("Profiles")
        .sheet(isPresented: $showingAddProfile) {
            NavigationStack {
                PlozziOSAddProfileView(appModel: appModel)
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                PlozziOSProfileEditorView(
                    profile: profile,
                    onSave: { name, emoji in
                        appModel.updateProfile(
                            profile.id,
                            name: name,
                            emoji: emoji
                        )
                        editingProfile = nil
                    },
                    onCancel: { editingProfile = nil }
                )
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
    }
}

private struct PlozziOSAddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel
    @State private var name = ""
    @State private var emoji = "👤"

    var body: some View {
        Form {
            SettingsSectionGroup("Profile") {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("New Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    appModel.addProfile(name: name, emoji: emoji)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct PlozziOSAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: PlozziOSAppModel
    let account: Account
    let onRemove: () -> Void
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            SettingsSectionGroup("Account") {
                LabeledContent("Provider", value: account.server.provider.displayName)
                if !account.userName.isEmpty {
                    LabeledContent("User", value: account.userName)
                }
                LabeledContent("Server", value: account.server.name)
                LabeledContent("Address", value: account.server.baseURL.absoluteString)
            }

            if account.server.provider == .plex {
                SettingsSectionGroup("Plex Home") {
                    NavigationLink {
                        PlozziOSPlexHomeUserSettingsView(
                            appModel: appModel,
                            account: account
                        )
                    } label: {
                        Label("Plex User", systemImage: "person.crop.circle")
                    }
                }
            }

            if account.server.provider == .mediaShare {
                PlozziOSShareScanSection(
                    state: appModel.shareScanStatus.state(
                        forShareID: account.id
                    ),
                    onScan: {
                        appModel.rescanShare(accountID: account.id)
                    }
                )
            }

            SettingsSectionGroup {
                Button("Remove Account", role: .destructive) {
                    confirmRemoval = true
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle(account.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove \(account.server.name)?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                onRemove()
                dismiss()
            }
        } message: {
            Text("Credentials and locally cached data for this source will be removed.")
        }
    }
}

private struct PlozziOSShareScanSection: View {
    let state: ShareScanState?
    let onScan: () -> Void

    var body: some View {
        SettingsSectionGroup("Library") {
            if let state, state.isBusy {
                LabeledContent(state.phase) {
                    if let detail = state.progressDetail {
                        Text(detail)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                    }
                }
                if let fraction = state.enrichFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            } else {
                LabeledContent("Last scanned") {
                    if let date = state?.lastScanAt {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                }
            }

            Button("Scan Now", systemImage: "arrow.clockwise", action: onScan)
                .disabled(state?.isBusy == true)
        }
    }
}

struct PlozziOSPlexHomeUserSettingsView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    @State private var users: [PlexHomeUser] = []
    @State private var isLoading = false

    var body: some View {
        List {
            SettingsSectionGroup("Account owner") {
                userButton(
                    name: account.userName.isEmpty ? "Plex Account Owner" : account.userName,
                    avatarURL: nil,
                    requiresPIN: false,
                    user: nil
                )
            }

            SettingsSectionGroup("Home users") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading Plex Home…")
                    }
                } else if users.isEmpty {
                    Text("No additional Plex Home users were found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(users.filter { !$0.isAdmin }) { user in
                        userButton(
                            name: user.name,
                            avatarURL: user.avatarURL,
                            requiresPIN: user.requiresPIN,
                            user: user
                        )
                    }
                }
            } footer: {
                Text("PIN-protected users must unlock when their Plozz profile becomes active.")
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("Plex User")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            users = await appModel.plexHomeUsers.plexHomeUsers(
                forAccountID: account.id
            )
            isLoading = false
        }
    }

    private func userButton(
        name: String,
        avatarURL: URL?,
        requiresPIN: Bool,
        user: PlexHomeUser?
    ) -> some View {
        Button {
            appModel.plexHomeUsers.setPlexHomeUserForActiveProfile(
                accountID: account.id,
                user: user
            )
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                Text(name)
                    .foregroundStyle(.primary)
                if requiresPIN {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected(user) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ user: PlexHomeUser?) -> Bool {
        let binding = appModel.profiles.activeProfile.homeUserBinding(
            forPlexAccount: account.id
        )
        if let user {
            return binding?.homeUserID == user.id
        }
        return binding == nil
    }
}

private struct PlozziOSAppearanceSettingsView: View {
    @Bindable var theme: ThemeSettingsModel
    @Bindable var transparency: TransparencyPreferenceModel
    @Bindable var cardStyle: CardStyleSettingsModel
    @Bindable var density: UIDensitySettingsModel
    @Bindable var watchIndicator: WatchStatusIndicatorSettingsModel

    var body: some View {
        Form {
            SettingsSectionGroup("Theme") {
                Picker("Appearance", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.symbolName)
                            .tag(theme)
                    }
                }
                Picker(
                    "Liquid Glass",
                    selection: $transparency.preference
                ) {
                    ForEach(TransparencyPreference.allCases) { preference in
                        Text(
                            preference == .system
                                ? "System"
                                : preference.displayName
                        )
                        .tag(preference)
                    }
                }
            }

            SettingsSectionGroup("Library cards") {
                Picker("Card style", selection: $cardStyle.style) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Picker("Display size", selection: $density.density) {
                    ForEach(UIDensity.allCases) { density in
                        Label(density.displayName, systemImage: density.symbolName)
                            .tag(density)
                    }
                }
                Picker("Watch indicator", selection: $watchIndicator.indicator) {
                    ForEach(WatchStatusIndicator.allCases) { indicator in
                        Text(indicator.displayName).tag(indicator)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .plozziOSSettingsSurface()
        .navigationTitle("Appearance")
    }
}

private struct PlozziOSSettingsSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.settingsPageSurface()
    }
}

private extension View {
    func plozziOSSettingsSurface() -> some View {
        modifier(PlozziOSSettingsSurface())
    }
}

private struct PlozziOSHomeSettingsView: View {
    @Bindable var hero: HeroSettingsModel
    let visibility: HomeLibraryVisibilityModel
    let accounts: [ResolvedAccount]
    let seerConfigured: Bool
    @State private var libraries: [HomeLibraryChoice] = []
    @State private var isLoadingLibraries = false

    var body: some View {
        Form {
            SettingsSectionGroup("Rows") {
                ForEach(HomeGlobalRow.allCases, id: \.rawValue) { row in
                    Toggle(
                        row.title,
                        isOn: Binding(
                            get: { visibility.isGlobalRowEnabled(row) },
                            set: { visibility.setGlobalRowEnabled($0, for: row) }
                        )
                    )
                }
                Toggle(
                    "Merge libraries",
                    isOn: Binding(
                        get: { visibility.visibility.mergeLibrariesOnHome },
                        set: { merge in
                            visibility.setMergeLibrariesOnHome(merge)
                            if !merge {
                                visibility.seedLibraryRowsIfNeeded(
                                    libraries.flatMap { library in
                                        LibraryHomeRowKind.allCases.map {
                                            (library.key, $0)
                                        }
                                    }
                                )
                            }
                        }
                    )
                )
            }

            SettingsSectionGroup("Libraries") {
                if isLoadingLibraries, libraries.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading libraries…")
                    }
                } else if libraries.isEmpty {
                    Text("No video libraries are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(libraries) { library in
                        NavigationLink {
                            PlozziOSLibraryHomeSettingsView(
                                library: library,
                                visibility: visibility
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.title)
                                Text(library.serverName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Choose which libraries and library-specific rows appear on Home.")
            }

            SettingsSectionGroup("Hero carousel") {
                Toggle("Show hero", isOn: $hero.settings.isEnabled)
                if hero.settings.isEnabled {
                    Toggle("Hide watched titles", isOn: $hero.settings.hideWatched)
                    Toggle("Auto-advance", isOn: $hero.settings.autoAdvance)
                }
            }

            if hero.settings.isEnabled {
                SettingsSectionGroup("Hero sources") {
                    ForEach(orderedHeroSources, id: \.self) { source in
                        Toggle(
                            source.displayName,
                            isOn: Binding(
                                get: {
                                    source == .featured && !seerConfigured
                                        ? false
                                        : hero.settings.sources.contains(source)
                                },
                                set: { _ in toggleSource(source) }
                            )
                        )
                        .disabled(source == .featured && !seerConfigured)
                    }
                }

                if hero.settings.isEnabled(.randomFromLibrary) {
                    SettingsSectionGroup("Random libraries") {
                        if randomEligibleLibraries.isEmpty {
                            Text("No movie or TV libraries are enabled on Home.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(randomEligibleLibraries) { library in
                                Toggle(
                                    library.title,
                                    isOn: Binding(
                                        get: {
                                            isRandomLibraryEnabled(library.key)
                                        },
                                        set: { _ in
                                            toggleRandomLibrary(library.key)
                                        }
                                    )
                                )
                            }
                        }
                    } footer: {
                        Text("Leave every library selected to include all enabled libraries.")
                    }
                }
            }

            if hero.settings.isEnabled {
                SettingsSectionGroup("Rotation") {
                    Stepper(
                        "Items: \(hero.settings.maxItems)",
                        value: $hero.settings.maxItems,
                        in: HeroSettings.maxItemsRange
                    )
                    if hero.settings.autoAdvance {
                        Stepper(
                            "Every \(hero.settings.autoAdvanceSeconds) seconds",
                            value: $hero.settings.autoAdvanceSeconds,
                            in: HeroSettings.autoAdvanceRange
                        )
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .plozziOSSettingsSurface()
        .navigationTitle("Customize Home")
        .task(id: accounts.map(\.account.id)) {
            await loadLibraries()
        }
    }

    private var orderedHeroSources: [HeroSourceKind] {
        HeroSourceKind.allCases.filter { $0 != .featured } + [.featured]
    }

    private var randomEligibleLibraries: [HomeLibraryChoice] {
        libraries.filter {
            ($0.library.kind == .movie || $0.library.kind == .series)
                && visibility.isVisibleOnHome($0.key)
        }
    }

    private func toggleSource(_ source: HeroSourceKind) {
        guard source != .featured || seerConfigured else { return }
        var enabled = Set(hero.settings.sources)
        if enabled.contains(source) {
            enabled.remove(source)
        } else {
            enabled.insert(source)
        }
        hero.settings.sources = HeroSourceKind.allCases.filter(enabled.contains)
    }

    private func isRandomLibraryEnabled(_ key: String) -> Bool {
        let selected = hero.settings.randomLibraryKeys
        return selected.isEmpty || selected.contains(key)
    }

    private func toggleRandomLibrary(_ key: String) {
        let allKeys = Set(randomEligibleLibraries.map(\.key))
        var selected = hero.settings.randomLibraryKeys.isEmpty
            ? allKeys
            : hero.settings.randomLibraryKeys
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
        selected.formIntersection(allKeys)
        hero.settings.randomLibraryKeys = selected == allKeys ? [] : selected
    }

    private func loadLibraries() async {
        isLoadingLibraries = true
        defer { isLoadingLibraries = false }
        var loaded: [HomeLibraryChoice] = []
        for resolved in accounts {
            guard let libraries = try? await resolved.provider.libraries() else {
                continue
            }
            loaded.append(
                contentsOf: libraries
                    .filter { !$0.isMusic }
                    .map {
                        HomeLibraryChoice(
                            accountID: resolved.account.id,
                            serverName: resolved.account.server.name,
                            library: $0
                        )
                    }
            )
        }
        libraries = loaded.sorted {
            if $0.serverName != $1.serverName {
                return $0.serverName.localizedStandardCompare($1.serverName)
                    == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

private struct HomeLibraryChoice: Identifiable {
    let accountID: String
    let serverName: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
    var title: String { library.title }
}

private struct PlozziOSLibraryHomeSettingsView: View {
    let library: HomeLibraryChoice
    let visibility: HomeLibraryVisibilityModel

    var body: some View {
        Form {
            SettingsSectionGroup {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { visibility.isEnabled(library.key) },
                        set: { visibility.setEnabled($0, for: library.key) }
                    )
                )
            } footer: {
                Text("Disabled libraries are hidden from Home and library browsing.")
            }

            if !visibility.mergeLibrariesOnHome {
                SettingsSectionGroup("Home rows") {
                    ForEach(LibraryHomeRowKind.allCases, id: \.rawValue) { kind in
                        Toggle(
                            kind.displayName,
                            isOn: Binding(
                                get: {
                                    visibility.isLibraryRowEnabled(
                                        library.key,
                                        kind: kind
                                    )
                                },
                                set: {
                                    visibility.setLibraryRowEnabled(
                                        $0,
                                        libraryKey: library.key,
                                        kind: kind
                                    )
                                }
                            )
                        )
                        .disabled(!visibility.isEnabled(library.key))
                    }
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle(library.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSPlaybackSettingsView: View {
    @Bindable var model: PlaybackSettingsModel
    @Bindable var audioPolicy: AudioPolicyModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    @Bindable var themeMusic: ThemeMusicSettingsModel

    private static let policyCategories: [ContentCategory] = [.movie, .tvShow, .anime]
    private static let audioOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map {
            .language($0.code)
        }

    var body: some View {
        Form {
            SettingsSectionGroup("Skipping") {
                Picker("Intros and credits", selection: $model.settings.skipIntros) {
                    ForEach(SkipIntrosMode.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Skip backward", selection: $model.settings.skipBackwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Skip forward", selection: $model.settings.skipForwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Resume rewind", selection: $model.settings.resumeRewindInterval) {
                    ForEach(ResumeRewindInterval.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
            }

            SettingsSectionGroup("Playback") {
                Toggle("Seek without pausing", isOn: $model.settings.seekWithoutPausing)
                Toggle("Show Up Next card", isOn: $model.settings.showUpNextCard)
                if model.settings.showUpNextCard {
                    Picker("Up Next lead time", selection: $model.settings.upNextLeadSeconds) {
                        ForEach(PlaybackSettings.upNextLeadSecondsOptions, id: \.self) {
                            Text("\($0) sec").tag($0)
                        }
                    }
                }
                Toggle(
                    "Sync watch state across servers",
                    isOn: $model.settings.syncWatchAcrossServers
                )
            }

            SettingsSectionGroup("Hero Background") {
                Picker(
                    "Background",
                    selection: $heroBackground.settings.mode
                ) {
                    ForEach(HeroBackgroundMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if heroBackground.settings.mode == .trailer {
                    Toggle(
                        "Mute trailer audio",
                        isOn: $heroBackground.settings.trailerMuted
                    )
                }
                if heroBackground.settings.mode == .themeMusic {
                    Picker(
                        "Theme music volume",
                        selection: $themeMusic.settings.volume
                    ) {
                        ForEach(ThemeMusicVolume.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
            }

            SettingsSectionGroup("Tracks") {
                Picker("Preferred audio", selection: $model.settings.audioLanguagePreference) {
                    ForEach(Self.audioOptions, id: \.self) { preference in
                        Text(audioName(preference)).tag(preference)
                    }
                }
                Toggle("Different default per type", isOn: audioOverridesEnabled)
                if !audioPolicy.overrides.isEmpty {
                    ForEach(Self.policyCategories, id: \.self) { category in
                        Picker(
                            category.displayName,
                            selection: audioBinding(for: category)
                        ) {
                            ForEach(Self.audioOptions, id: \.self) { preference in
                                Text(audioName(preference)).tag(preference)
                            }
                        }
                    }
                }
                Toggle(
                    "Remember audio per series",
                    isOn: $model.settings.rememberAudioTrackPerSeries
                )
                Toggle(
                    "Remember subtitles per series",
                    isOn: $model.settings.rememberSubtitleTrackPerSeries
                )
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .plozziOSSettingsSurface()
        .navigationTitle("Playback")
    }

    private var audioOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !audioPolicy.overrides.isEmpty },
            set: {
                audioPolicy.overrides = $0
                    ? AudioPolicy.smartDefaultOverrides()
                    : [:]
            }
        )
    }

    private func audioBinding(
        for category: ContentCategory
    ) -> Binding<AudioLanguagePreference> {
        Binding(
            get: {
                audioPolicy.overrides[category]
                    ?? model.settings.audioLanguagePreference
            },
            set: { audioPolicy.overrides[category] = $0 }
        )
    }

    private func audioName(_ preference: AudioLanguagePreference) -> String {
        switch preference {
        case .original:
            return "Original language"
        case .device:
            return "Device language"
        case .language(let code):
            return SubtitleLanguageCatalog.languages.first {
                $0.code == code
            }?.name ?? code
        }
    }
}

private struct PlozziOSSubtitleSettingsView: View {
    @Bindable var behavior: SubtitleBehaviorModel
    @Bindable var policy: SubtitlePolicyModel
    @Bindable var style: SubtitleStyleModel

    private static let policyCategories: [SubtitleContentCategory] =
        [.movie, .tvShow, .anime]

    var body: some View {
        Form {
            SettingsSectionGroup("Appearance") {
                Toggle("Follow system style", isOn: $style.style.followsSystemStyle)
                Picker("Font", selection: $style.style.fontFamily) {
                    ForEach(SubtitleFontFamily.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Weight", selection: $style.style.fontWeight) {
                    ForEach(style.style.fontFamily.availableWeights, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                LabeledContent("Size") {
                    Slider(value: $style.style.fontScale, in: 0.6...2.0)
                        .frame(maxWidth: 360)
                }
                LabeledContent("Opacity") {
                    Slider(value: $style.style.opacity, in: 0.2...1.0)
                        .frame(maxWidth: 360)
                }
                Toggle("Background", isOn: $style.style.background.isEnabled)
            }

            SettingsSectionGroup("Behavior") {
                Picker("Automatic subtitles", selection: $behavior.settings.subtitleMode) {
                    ForEach(SubtitleMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                    Toggle("Different default per type", isOn: subtitleOverridesEnabled)
                    if !policy.overrides.isEmpty {
                        ForEach(Self.policyCategories, id: \.self) { category in
                            Picker(category.displayName, selection: modeBinding(for: category)) {
                                ForEach(SubtitleMode.allCases, id: \.self) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                        }
                    }
                }
                Toggle(
                    "Download subtitles automatically",
                    isOn: $behavior.settings.autoDownloadSubtitles
                )
                TextField(
                    "Preferred language code",
                    text: Binding(
                        get: { behavior.settings.preferredSubtitleLanguage ?? "" },
                        set: {
                            behavior.settings.preferredSubtitleLanguage =
                                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : $0
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            SettingsSectionGroup("Subtitle search") {
                Picker(
                    "Hearing impaired",
                    selection: $behavior.settings.hearingImpairedPreference
                ) {
                    ForEach(HearingImpairedPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker(
                    "Forced subtitles",
                    selection: $behavior.settings.forcedSearchPreference
                ) {
                    ForEach(ForcedSubtitlePreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .plozziOSSettingsSurface()
        .navigationTitle("Subtitles")
    }

    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: behavior.settings).basePolicy
    }

    private var subtitleOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !policy.overrides.isEmpty },
            set: {
                policy.overrides = $0
                    ? SubtitlePolicy.smartDefaultOverrides(base: baseRule)
                    : [:]
            }
        )
    }

    private func modeBinding(
        for category: SubtitleContentCategory
    ) -> Binding<SubtitleMode> {
        Binding(
            get: { policy.overrides[category]?.mode ?? baseRule.mode },
            set: {
                var rule = policy.overrides[category] ?? baseRule
                rule.mode = $0
                policy.overrides[category] = rule
            }
        )
    }
}

private struct PlozziOSSpoilerSettingsView: View {
    @Bindable var model: SpoilerSettingsModel

    var body: some View {
        Form {
            SettingsSectionGroup {
                Toggle("Protect unwatched episodes", isOn: $model.settings.isEnabled)
                Picker("Thumbnail treatment", selection: $model.settings.mode) {
                    ForEach(SpoilerSettings.Mode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.isEnabled)
                Toggle(
                    "Hide ratings until watched",
                    isOn: $model.settings.hideRatingsUntilWatched
                )
            } footer: {
                Text("Episode titles, summaries, and artwork can be hidden until you watch them.")
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("Spoilers")
    }
}

private struct PlozziOSNightShiftSettingsView: View {
    @Bindable var model: NightShiftSettingsModel

    var body: some View {
        Form {
            SettingsSectionGroup {
                Toggle("Circadian Mode", isOn: $model.settings.isEnabled)
                Picker("Schedule", selection: $model.settings.scheduleMode) {
                    ForEach(NightShiftScheduleMode.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.isEnabled)

                if model.settings.isEnabled {
                    scheduleDetails
                }
            } footer: {
                Text(model.scheduleSummary())
            }

            if model.settings.isEnabled {
                SettingsSectionGroup("Picture") {
                    Picker("Warmth", selection: $model.settings.warmth) {
                        ForEach(NightShiftWarmth.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("Dimness", selection: $model.settings.dimness) {
                        ForEach(NightShiftDimness.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if model.settings.scheduleMode != .alwaysOn {
                        Picker("Fade", selection: $model.settings.fadeMinutes) {
                            ForEach(fadeOptions, id: \.self) { minutes in
                                Text(fadeLabel(minutes))
                                    .tag(minutes)
                            }
                        }
                    }
                }

                SettingsSectionGroup("Preview") {
                    Toggle("Preview at Full Strength", isOn: $model.isPreviewing)
                    Button("Preview a Day", systemImage: "sun.and.horizon") {
                        model.runDayNightPreview()
                    }
                    if model.previewProgress != nil {
                        LabeledContent("Simulated time") {
                            Text(model.previewClockText)
                                .monospacedDigit()
                        }
                        ProgressView(value: model.previewProgress ?? 0)
                    }
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("Circadian Mode")
        .onChange(of: model.settings.isEnabled) { _, enabled in
            if !enabled {
                model.isPreviewing = false
            }
        }
        .onDisappear {
            model.isPreviewing = false
        }
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        switch model.settings.scheduleMode {
        case .solar:
            Picker("Location", selection: $model.settings.regionID) {
                ForEach(NightShiftRegion.sortedCatalog) { region in
                    Text(region.name).tag(region.id)
                }
            }
        case .manual:
            DatePicker(
                "Turns on",
                selection: timeBinding(for: \.manualOnMinutes),
                displayedComponents: .hourAndMinute
            )
            DatePicker(
                "Turns off",
                selection: timeBinding(for: \.manualOffMinutes),
                displayedComponents: .hourAndMinute
            )
        case .alwaysOn:
            EmptyView()
        }
    }

    private func timeBinding(
        for keyPath: WritableKeyPath<NightShiftSettings, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings[keyPath: keyPath]
                var components = DateComponents()
                components.year = 2001
                components.month = 1
                components.day = 1
                components.hour = minutes / 60
                components.minute = minutes % 60
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                model.settings[keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private var fadeOptions: [Int] {
        Array(
            Set(
                NightShiftSettingsModel.fadeOptions
                    + [model.settings.fadeMinutes]
            )
        )
        .sorted()
    }

    private func fadeLabel(_ minutes: Int) -> String {
        minutes == 0
            ? "Off"
            : NightShiftSettingsModel.fadeLabel(minutes: minutes)
    }
}

private struct PlozziOSAttributionsView: View {
    var body: some View {
        List {
            Text(PlozzAttributions.introduction)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(PlozzAttributions.entries) { entry in
                SettingsSectionGroup(entry.title) {
                    Text(entry.detail)
                    if !entry.licenses.isEmpty {
                        PlozziOSLicenseBadges(licenses: entry.licenses)
                    }
                }
            }
        }
        .plozziOSSettingsSurface()
        .navigationTitle("Attributions")
    }
}

private struct PlozziOSLicenseBadges: View {
    let licenses: [PlozzAttributionLicense]

    var body: some View {
        HStack {
            ForEach(licenses) { license in
                Text(license.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(licenses.map(\.label).joined(separator: ", "))
    }
}
#endif
