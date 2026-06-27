#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct AppearanceDetailView: View {
    @Bindable var theme: ThemeSettingsModel
    @Environment(MusicPlayerSettingsModel.self) private var musicPlayer
    /// App-wide (global) — persists across all profiles. Same un-namespaced
    /// `@AppStorage` key RootView reads. Do not move into a per-profile store.
    /// See AGENTS.local.md ("Per-profile vs app-wide settings").
    @AppStorage("reduceTransparencyOverride") private var reduceTransparency = false

    var body: some View {
        @Bindable var musicPlayer = musicPlayer
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Appearance").font(.largeTitle.bold())
                SettingsPanel(
                    title: "Theme",
                    footer: "Choose how Plozz looks. Theme applies to the active profile only."
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(AppTheme.allCases) { option in
                                Button {
                                    theme.theme = option
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: option.symbolName)
                                        Text(option.displayName)
                                        Image(systemName: "checkmark.circle.fill")
                                            .opacity(theme.theme == option ? 1 : 0)
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

                SettingsPanel(
                    title: "Music Player",
                    footer: "Sets the look of the full-screen Now Playing player. Match Theme follows your app theme; or pin a fixed look."
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
                                            Image(systemName: "checkmark.circle.fill")
                                                .opacity(musicPlayer.appearance == option ? 1 : 0)
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

                SettingsPanel(
                    title: "Transparency",
                    footer: "Replaces the translucent “liquid glass” blur on cards, menus and overlays with solid surfaces. Turns on automatically when Reduce Transparency is enabled in tvOS Accessibility settings."
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Reduce transparency", isOn: $reduceTransparency)
                    }
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
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
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}
#endif