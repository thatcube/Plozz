#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct AppearanceDetailView: View {
    @Bindable var theme: ThemeSettingsModel
    @Environment(MusicPlayerSettingsModel.self) private var musicPlayer
    @Environment(UIDensitySettingsModel.self) private var density
    /// App-wide (global) — persists across all profiles. Same un-namespaced
    /// `@AppStorage` key RootView reads. Do not move into a per-profile store.
    /// See AGENTS.local.md ("Per-profile vs app-wide settings").
    @AppStorage(TransparencyPreference.storageKey) private var transparencyPreferenceRaw = TransparencyPreference.default.rawValue

    private var transparencyPreference: TransparencyPreference {
        TransparencyPreference(rawValue: transparencyPreferenceRaw) ?? .default
    }

    var body: some View {
        @Bindable var musicPlayer = musicPlayer
        @Bindable var density = density
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Appearance").font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 24) {
                    // Theme
                    LabeledSettingRow("Theme", labelWidth: 300) {
                        SettingsOptionPicker(
                            options: AppTheme.allCases,
                            selection: $theme.theme,
                            icon: { $0.symbolName },
                            title: { $0.displayName }
                        )
                    }

                    sectionDivider

                    // Display Size
                    LabeledSettingRow(
                        "Display Size",
                        subtitle: "Scales card size, columns and spacing.",
                        labelWidth: 300
                    ) {
                        SettingsOptionPicker(
                            options: UIDensity.allCases,
                            selection: $density.density,
                            icon: { $0.symbolName },
                            title: { $0.displayName }
                        )
                    }

                    sectionDivider

                    // Transparency
                    LabeledSettingRow("Transparency", subtitle: "Liquid glass", labelWidth: 300) {
                        SettingsOptionPicker(
                            options: TransparencyPreference.allCases,
                            selection: Binding(
                                get: { transparencyPreference },
                                set: { transparencyPreferenceRaw = $0.rawValue }
                            ),
                            icon: { $0.symbolName },
                            title: { $0.displayName }
                        )
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

                SettingsPanel(
                    title: "Music Player"
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledSettingRow("Style", labelWidth: 300) {
                            SettingsOptionPicker(
                                options: MusicPlayerAppearance.allCases,
                                selection: $musicPlayer.appearance,
                                icon: { $0.symbolName },
                                title: { $0.displayName }
                            )
                        }

                        Toggle("Show album name, audio quality & lyrics source", isOn: $musicPlayer.showTrackDetails)
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }

    /// Hairline rule between the joined Appearance sections so they read as one
    /// grouped container rather than separate cards. The negative horizontal
    /// padding cancels the container's 28 pt content inset *minus* the 1 pt
    /// border stroke, so the rule meets the inner edge of the border exactly
    /// without overlapping it (overlapping would stack the two translucent
    /// fills into a darker dot at each end).
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, -27)
    }
}

struct CaptionsDetailView: View {
    @Bindable var captions: CaptionSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Captions").font(.largeTitle.bold())
                SettingsPanel(
                    title: "Caption style",
                    footer: "These caption settings are also available from the player while you watch."
                ) {
                    CaptionSettingsCard(settings: $captions.settings)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}

struct SpoilersDetailView: View {
    @Bindable var spoilers: SpoilerSettingsModel

    private var modeExplanation: String {
        switch spoilers.settings.mode {
        case .blur:
            return "Episode thumbnails are blurred until watched. Titles and descriptions stay hidden until you finish the episode."
        case .placeholder:
            return "Episode thumbnails are replaced with generic series art and the episode number, so no real frame is ever shown. Titles and descriptions stay hidden until you finish the episode."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Spoiler Protection").font(.largeTitle.bold())
                SettingsPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Hide spoilers for unwatched episodes", isOn: $spoilers.settings.isEnabled)

                        if spoilers.settings.isEnabled {
                            LabeledSettingRow("Mode", labelWidth: 220) {
                                SettingsOptionPicker(
                                    options: SpoilerSettings.Mode.allCases,
                                    selection: $spoilers.settings.mode,
                                    title: { $0.displayName }
                                )
                            }

                            Text(modeExplanation)
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
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}
struct PlaybackDetailView: View {
    @Bindable var playback: PlaybackSettingsModel

    private var syncExplanation: String {
        playback.settings.syncWatchAcrossServers
            ? "When you finish, resume, or mark a title, Plozz updates every server that has it — so your progress follows you no matter which server you watch on next."
            : "Plozz only updates the server you actually watched on. Other servers that have the same title are left untouched."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Playback").font(.largeTitle.bold())

                SettingsPanel(
                    title: "Captions",
                    footer: "Adjust caption font, size and colours. These settings are also available from the player while you watch."
                ) {
                    NavigationLink(value: SettingsRoute.captions) {
                        HStack(spacing: 16) {
                            Image(systemName: "captions.bubble")
                                .font(.title3)
                                .frame(width: 44)
                            Text("Caption style").font(.callout.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                }

                SettingsPanel(
                    title: "Skip Intervals",
                    footer: "How far left/right presses on the Siri Remote jump during playback."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledSettingRow("Skip Backward", labelWidth: 220) {
                            SettingsOptionPicker(
                                options: SkipInterval.allCases,
                                selection: $playback.settings.skipBackwardInterval,
                                icon: { _ in "gobackward" },
                                title: { $0.title }
                            )
                        }

                        LabeledSettingRow("Skip Forward", labelWidth: 220) {
                            SettingsOptionPicker(
                                options: SkipInterval.allCases,
                                selection: $playback.settings.skipForwardInterval,
                                icon: { _ in "goforward" },
                                title: { $0.title }
                            )
                        }
                    }
                }

                SettingsPanel(
                    title: "Skip Intros & Credits",
                    footer: "When your server has detected intro and credit markers, Plozz can show a Skip button — or skip for you automatically — during playback. Requires server-side markers — Plex Pass on Plex, or the Media Segments / Intro Skipper feature on Jellyfin."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledSettingRow("Skip Intros", labelWidth: 220) {
                            SettingsOptionPicker(
                                options: SkipIntrosMode.allCases,
                                selection: $playback.settings.skipIntros,
                                title: { $0.title }
                            )
                        }

                        Text(playback.settings.skipIntros.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsPanel(
                    title: "Watch Status Sync",
                    footer: "Applies to this profile only and takes effect immediately — no need to restart. Trakt scrobbling is unaffected either way."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Sync watch status across all my servers", isOn: $playback.settings.syncWatchAcrossServers)

                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: playback.settings.syncWatchAcrossServers ? "arrow.triangle.2.circlepath" : "externaldrive")
                                .font(.title3)
                                .foregroundStyle(playback.settings.syncWatchAcrossServers ? Color.accentColor : .secondary)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playback.settings.syncWatchAcrossServers ? "All servers" : "This server only")
                                    .font(.callout.weight(.semibold))
                                Text(syncExplanation)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}
#endif