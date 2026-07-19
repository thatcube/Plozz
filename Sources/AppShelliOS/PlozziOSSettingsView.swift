#if os(iOS)
import CoreModels
import SwiftUI

struct PlozziOSSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var confirmSignOutAll = false

    var body: some View {
        List {
            Section("Profiles") {
                NavigationLink {
                    PlozziOSProfilesView(appModel: appModel)
                } label: {
                    Label(
                        appModel.profiles.activeProfile.name,
                        systemImage: "person.2"
                    )
                }
            }

            Section("Services") {
                NavigationLink {
                    PlozziOSSeerrSettingsView(appModel: appModel)
                } label: {
                    Label("Requests", systemImage: "plus.rectangle.on.folder")
                }
            }

            Section("Media sources") {
                ForEach(appModel.accounts) { account in
                    NavigationLink {
                        PlozziOSAccountDetailView(
                            appModel: appModel,
                            account: account,
                            onRemove: {
                                appModel.removeAccount(id: account.id)
                            }
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(account.server.name)
                                if !account.userName.isEmpty {
                                    Text(account.userName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }
                }

                Button("Add Server", systemImage: "plus", action: onAddServer)
                NavigationLink {
                    PlozziOSAddShareView(appModel: appModel)
                } label: {
                    Label("Add Network Share", systemImage: "externaldrive.connected.to.line.below")
                }
            }

            Section("Preferences") {
                NavigationLink {
                    PlozziOSTrackerSettingsView(appModel: appModel)
                } label: {
                    Label("Trackers", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    PlozziOSAppearanceSettingsView(
                        theme: appModel.settings.theme,
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
                    Label("Home", systemImage: "house")
                }
                NavigationLink {
                    PlozziOSPlaybackSettingsView(
                        model: appModel.settings.playback,
                        audioPolicy: appModel.settings.audioPolicy
                    )
                } label: {
                    Label("Playback", systemImage: "play.rectangle")
                }
                NavigationLink {
                    PlozziOSDownloadSettingsView(model: appModel.downloads)
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
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
                    Label("Night Shift", systemImage: "moon.stars")
                }
            }

            Section("Support") {
                NavigationLink {
                    PlozziOSDiagnosticsSettingsView(
                        appModel: appModel,
                        model: appModel.settings.diagnostics,
                        crashReporting: appModel.crashReporting
                    )
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
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
                Section {
                    Label(accountError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
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
    let appModel: PlozziOSAppModel
    @State private var showingAddProfile = false

    var body: some View {
        List {
            if appModel.profiles.profiles.count > 1 {
                Section {
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
                } footer: {
                    Text("Choose a household profile whenever Plozz opens.")
                }
            }

            Section("Who’s watching?") {
                ForEach(appModel.profiles.profiles) { profile in
                    NavigationLink {
                        PlozziOSProfileDetailView(
                            appModel: appModel,
                            profile: profile
                        )
                    } label: {
                        HStack {
                            Text(profile.avatarEmoji ?? "👤")
                            Text(profile.name)
                            Spacer()
                            if profile.id == appModel.profiles.activeProfileID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
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
        .navigationTitle("Profiles")
        .sheet(isPresented: $showingAddProfile) {
            NavigationStack {
                PlozziOSAddProfileView(appModel: appModel)
            }
        }
    }
}

private struct PlozziOSProfileDetailView: View {
    let appModel: PlozziOSAppModel
    let profile: Profile

    var body: some View {
        Form {
            Section {
                Button(
                    profile.id == appModel.profiles.activeProfileID
                        ? "Current Profile"
                        : "Switch to \(profile.name)"
                ) {
                    appModel.selectProfile(profile.id)
                }
                .disabled(profile.id == appModel.profiles.activeProfileID)
            }

            Section("Media sources") {
                ForEach(appModel.accounts) { account in
                    Toggle(
                        account.server.name,
                        isOn: Binding(
                            get: {
                                appModel.activeAccountIDs(for: profile.id)
                                    .contains(account.id)
                            },
                            set: {
                                appModel.setAccount(
                                    account.id,
                                    enabled: $0,
                                    for: profile.id
                                )
                            }
                        )
                    )
                }
            }
        }
        .navigationTitle(profile.name)
    }
}

private struct PlozziOSAddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel
    @State private var name = ""
    @State private var emoji = "👤"

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
            }
        }
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

private struct PlozziOSAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: PlozziOSAppModel
    let account: Account
    let onRemove: () -> Void
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Provider", value: account.server.provider.displayName)
                if !account.userName.isEmpty {
                    LabeledContent("User", value: account.userName)
                }
                LabeledContent("Server", value: account.server.name)
                LabeledContent("Address", value: account.server.baseURL.absoluteString)
            }

            if account.server.provider == .plex {
                Section("Plex Home") {
                    NavigationLink {
                        PlozziOSPlexHomeUserSettingsView(
                            appModel: appModel,
                            account: account
                        )
                    } label: {
                        Label("Plex User", systemImage: "person.crop.circle")
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
            }

            Section {
                Button("Remove Account", role: .destructive) {
                    confirmRemoval = true
                }
            }
        }
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
        Section("Library") {
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

private struct PlozziOSPlexHomeUserSettingsView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    @State private var users: [PlexHomeUser] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                userButton(
                    name: account.userName.isEmpty ? "Plex Account Owner" : account.userName,
                    avatarURL: nil,
                    requiresPIN: false,
                    user: nil
                )
            } header: {
                Text("Account owner")
            }

            Section {
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
            } header: {
                Text("Home users")
            } footer: {
                Text("PIN-protected users must unlock when their Plozz profile becomes active.")
            }
        }
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
    @Bindable var cardStyle: CardStyleSettingsModel
    @Bindable var density: UIDensitySettingsModel
    @Bindable var watchIndicator: WatchStatusIndicatorSettingsModel

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.symbolName)
                            .tag(theme)
                    }
                }
            }

            Section("Library cards") {
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
        .navigationTitle("Appearance")
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
            Section("Rows") {
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

            Section {
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
            } header: {
                Text("Libraries")
            } footer: {
                Text("Choose which libraries and library-specific rows appear on Home.")
            }

            Section("Hero carousel") {
                Toggle("Show hero", isOn: $hero.settings.isEnabled)
                if hero.settings.isEnabled {
                    Toggle("Hide watched titles", isOn: $hero.settings.hideWatched)
                    Toggle("Auto-advance", isOn: $hero.settings.autoAdvance)
                    Toggle("Background trailers", isOn: $hero.settings.trailersEnabled)
                }
            }

            if hero.settings.isEnabled {
                Section("Hero sources") {
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
                    Section {
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
                    } header: {
                        Text("Random libraries")
                    } footer: {
                        Text("Leave every library selected to include all enabled libraries.")
                    }
                }
            }

            if hero.settings.isEnabled {
                Section("Rotation") {
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
        .navigationTitle("Home")
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
            Section {
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
                Section("Home rows") {
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
        .navigationTitle(library.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSPlaybackSettingsView: View {
    @Bindable var model: PlaybackSettingsModel
    @Bindable var audioPolicy: AudioPolicyModel

    private static let policyCategories: [ContentCategory] = [.movie, .tvShow, .anime]
    private static let audioOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map {
            .language($0.code)
        }

    var body: some View {
        Form {
            Section("Skipping") {
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

            Section("Playback") {
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

            Section("Tracks") {
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
            Section("Appearance") {
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

            Section("Behavior") {
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

            Section("Subtitle search") {
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
            Section {
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
        .navigationTitle("Spoilers")
    }
}

private struct PlozziOSNightShiftSettingsView: View {
    @Bindable var model: NightShiftSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Night Shift", isOn: $model.settings.isEnabled)
                Picker("Schedule", selection: $model.settings.scheduleMode) {
                    ForEach(NightShiftScheduleMode.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
            }

            Section("Picture") {
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
                Stepper(
                    "Fade: \(model.settings.fadeMinutes) minutes",
                    value: $model.settings.fadeMinutes,
                    in: 0...180,
                    step: 15
                )
            }
        }
        .navigationTitle("Night Shift")
    }
}

private struct PlozziOSAttributionsView: View {
    var body: some View {
        List {
            Section {
                Text("Plozz is free and open source under GPL-3.0 with an App Store exception.")
                Text("Plozz is an unofficial client and is not affiliated with Jellyfin or Plex.")
            }
            attribution(
                "AetherEngine & FFmpeg",
                "Playback is powered by AetherEngine. Media processing uses FFmpeg under LGPL licenses."
            )
            attribution(
                "Networking",
                "Network shares use AMSMB2, SwiftNIO SSH, Network.framework, and protocol-specific open-source components."
            )
            attribution(
                "Media metadata",
                "This product may use TMDB metadata but is not endorsed or certified by TMDB."
            )
            attribution(
                "Open-source licenses",
                "Third-party components retain their respective MIT, BSD, Apache, ISC, LGPL, and other licenses."
            )
        }
        .navigationTitle("Attributions")
    }

    private func attribution(_ title: String, _ detail: String) -> some View {
        Section(title) {
            Text(detail)
        }
    }
}
#endif
