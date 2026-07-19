#if os(iOS)
import CoreModels
import SwiftUI

struct PlozziOSSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        List {
            Section("Media sources") {
                ForEach(appModel.accounts) { account in
                    NavigationLink {
                        PlozziOSAccountDetailView(
                            account: account,
                            onRemove: {
                                appModel.removeAccount(id: account.id)
                            }
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(account.server.name)
                                Text(account.userName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                    }
                }

                Button("Add Server", systemImage: "plus", action: onAddServer)
            }

            Section("Preferences") {
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
                        visibility: appModel.settings.homeVisibility
                    )
                } label: {
                    Label("Home", systemImage: "house")
                }
                NavigationLink {
                    PlozziOSPlaybackSettingsView(model: appModel.settings.playback)
                } label: {
                    Label("Playback", systemImage: "play.rectangle")
                }
                NavigationLink {
                    PlozziOSSubtitleSettingsView(
                        behavior: appModel.settings.subtitleBehavior,
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
                    PlozziOSDiagnosticsSettingsView(model: appModel.settings.diagnostics)
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                }
            }

            if let accountError = appModel.accountError {
                Section {
                    Label(accountError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct PlozziOSAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let account: Account
    let onRemove: () -> Void

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Provider", value: account.server.provider.displayName)
                LabeledContent("User", value: account.userName)
                LabeledContent("Server", value: account.server.name)
                LabeledContent("Address", value: account.server.baseURL.absoluteString)
            }

            Section {
                Button("Remove Account", role: .destructive) {
                    onRemove()
                    dismiss()
                }
            }
        }
        .navigationTitle(account.server.name)
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationTitle("Appearance")
    }
}

private struct PlozziOSHomeSettingsView: View {
    @Bindable var hero: HeroSettingsModel
    let visibility: HomeLibraryVisibilityModel

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
                        set: { visibility.setMergeLibrariesOnHome($0) }
                    )
                )
            }

            Section("Hero carousel") {
                Toggle("Show hero", isOn: $hero.settings.isEnabled)
                Toggle("Hide watched titles", isOn: $hero.settings.hideWatched)
                Toggle("Auto-advance", isOn: $hero.settings.autoAdvance)
                Toggle("Background trailers", isOn: $hero.settings.trailersEnabled)
            }

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
        .navigationTitle("Home")
    }
}

private struct PlozziOSPlaybackSettingsView: View {
    @Bindable var model: PlaybackSettingsModel

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
                    Text("Original language").tag(AudioLanguagePreference.original)
                    Text("Device language").tag(AudioLanguagePreference.device)
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
        .navigationTitle("Playback")
    }
}

private struct PlozziOSSubtitleSettingsView: View {
    @Bindable var behavior: SubtitleBehaviorModel
    @Bindable var style: SubtitleStyleModel

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
                        .frame(maxWidth: 220)
                }
                LabeledContent("Opacity") {
                    Slider(value: $style.style.opacity, in: 0.2...1.0)
                        .frame(maxWidth: 220)
                }
                Toggle("Background", isOn: $style.style.background.isEnabled)
            }

            Section("Behavior") {
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
        }
        .navigationTitle("Subtitles")
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

private struct PlozziOSDiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Playback diagnostics", isOn: $model.settings.isEnabled)
                Toggle(
                    "Home performance overlay",
                    isOn: $model.settings.homePerformanceOverlayEnabled
                )
            } footer: {
                Text("Diagnostics are off by default and intended for troubleshooting.")
            }
        }
        .navigationTitle("Diagnostics")
    }
}
#endif
