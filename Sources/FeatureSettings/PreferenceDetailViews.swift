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

                VStack(alignment: .leading, spacing: 28) {
                    // Theme
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Theme").font(.headline.weight(.semibold))
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
                                    .buttonStyle(PlozzSeasonTabStyle(isSelected: theme.theme == option))
                                    .accessibilityValue(theme.theme == option ? "Selected" : "")
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .scrollClipDisabled()
                    }

                    sectionDivider

                    // Display Size
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Display Size").font(.headline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(UIDensity.allCases) { option in
                                    Button {
                                        density.density = option
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: option.symbolName)
                                            Text(option.displayName)
                                            if density.density == option {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                        .font(.headline)
                                        .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(PlozzSeasonTabStyle(isSelected: density.density == option))
                                    .accessibilityValue(density.density == option ? "Selected" : "")
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .scrollClipDisabled()
                        Text("Scales card size, columns and spacing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    sectionDivider

                    // Transparency
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Transparency (liquid glass)").font(.headline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(TransparencyPreference.allCases) { option in
                                    Button {
                                        transparencyPreferenceRaw = option.rawValue
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: option.symbolName)
                                            Text(option.displayName)
                                            if transparencyPreference == option {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                        .font(.headline)
                                        .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(PlozzSeasonTabStyle(isSelected: transparencyPreference == option))
                                    .accessibilityValue(transparencyPreference == option ? "Selected" : "")
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .scrollClipDisabled()
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
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(MusicPlayerAppearance.allCases) { option in
                                    Button {
                                        musicPlayer.appearance = option
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: option.symbolName)
                                            Text(option.displayName)
                                            if musicPlayer.appearance == option {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                        .font(.headline)
                                        .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(PlozzSeasonTabStyle(isSelected: musicPlayer.appearance == option))
                                    .accessibilityValue(musicPlayer.appearance == option ? "Selected" : "")
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .scrollClipDisabled()

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
                            OptionCardRow(
                                options: SpoilerSettings.Mode.allCases,
                                selection: $spoilers.settings.mode
                            ) { mode in
                                Text(mode.displayName)
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
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
                    title: "Skip Intros & Credits",
                    footer: "When your server has detected intro and credit markers, Plozz can show a Skip button — or skip for you automatically — during playback. Requires server-side markers — Plex Pass on Plex, or the Media Segments / Intro Skipper feature on Jellyfin."
                ) {
                    VStack(spacing: 4) {
                        ForEach(SkipIntrosMode.allCases, id: \.self) { mode in
                            Button {
                                playback.settings.skipIntros = mode
                            } label: {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mode.title).font(.callout.weight(.medium))
                                        Text(mode.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .font(.callout.weight(.semibold))
                                        .opacity(playback.settings.skipIntros == mode ? 1 : 0)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SettingsFocusButtonStyle())
                            .accessibilityValue(playback.settings.skipIntros == mode ? "Selected" : "")
                        }
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