#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct AppearanceDetailView: View {
    @Bindable var theme: ThemeSettingsModel
    @AppStorage("reduceTransparencyOverride") private var reduceTransparency = false

    var body: some View {
        ScrollView {
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

/// Now Playing preferences. Currently a single switch for the optional,
/// audiophile-leaning "track details" surface on the full-screen music player.
/// Reads/writes the same `@AppStorage` key the player observes, so the player
/// updates live without any extra plumbing.
struct NowPlayingDetailView: View {
    @AppStorage("musicShowTrackDetails") private var showTrackDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Now Playing").font(.largeTitle.bold())
                SettingsPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Show track details", isOn: $showTrackDetails)

                        Text("Adds the album name, the audio quality and format (e.g. \"Original AAC 44.1 kHz 320 kbps\"), and the lyrics source to the full-screen player. Off by default so the player stays focused on the artwork, song and artist.")
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
#endif
