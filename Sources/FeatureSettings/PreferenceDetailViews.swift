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
    /// The profile base subtitle mode/language lives in `CaptionSettings`.
    @Bindable var captions: CaptionSettingsModel
    /// Per-content-type overrides ("forced-only on movies, full subs on anime").
    @Bindable var subtitlePolicy: SubtitlePolicyModel
    /// Per-content-type audio-language overrides ("original audio for anime,
    /// device language for everything else").
    @Bindable var audioPolicy: AudioPolicyModel

    /// The three classifiable content types the per-type rules apply to, in the
    /// order shown in Settings (`.other` always follows the base, so it isn't
    /// shown as its own row).
    private static let policyCategories: [SubtitleContentCategory] = [.movie, .tvShow, .anime]

    /// Whether the profile has opted into per-content-type rules (any override set).
    private var perContentTypeEnabled: Bool { !subtitlePolicy.overrides.isEmpty }

    /// The profile base rule, derived live from the caption settings.
    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: captions.settings).basePolicy
    }

    /// Toggles the whole per-content-type matrix: adopting the smart seed
    /// (forced-only movies, full anime/TV) on, or clearing back to the single
    /// base everywhere off.
    private var perContentTypeBinding: Binding<Bool> {
        Binding(
            get: { perContentTypeEnabled },
            set: { on in
                subtitlePolicy.overrides = on
                    ? SubtitlePolicy.smartDefaultOverrides(base: baseRule)
                    : [:]
            }
        )
    }

    /// A picker binding for one category's subtitle mode, falling back to the
    /// base mode when no override is stored yet.
    private func modeBinding(for category: SubtitleContentCategory) -> Binding<CaptionSettings.SubtitleMode> {
        Binding(
            get: { subtitlePolicy.overrides[category]?.mode ?? baseRule.mode },
            set: { newMode in
                var rule = subtitlePolicy.overrides[category] ?? baseRule
                rule.mode = newMode
                subtitlePolicy.overrides[category] = rule
            }
        )
    }

    // MARK: Audio-language policy helpers

    /// The selectable audio-language preferences for the dropdowns: Original /
    /// Device, then the shared common-language list reused from the caption card.
    private static let audioPreferenceOptions: [AudioLanguagePreference] =
        [.original, .device] + CaptionSettingsCard.subtitleLanguages.map { .language($0.code) }

    /// Human-readable label for an audio-language preference.
    private static func audioPreferenceName(_ preference: AudioLanguagePreference) -> String {
        switch preference {
        case .original: return "Original"
        case .device: return "Device"
        case .language(let code):
            return CaptionSettingsCard.subtitleLanguages.first(where: { $0.code == code })?.name ?? code
        }
    }

    /// Whether the profile has opted into per-content-type audio rules.
    private var audioPerContentTypeEnabled: Bool { !audioPolicy.overrides.isEmpty }

    /// Toggles the whole per-content-type audio matrix: adopting the smart seed
    /// (original audio for anime, device language for movies/TV) on, or clearing
    /// back to the single base preference everywhere off.
    private var audioPerContentTypeBinding: Binding<Bool> {
        Binding(
            get: { audioPerContentTypeEnabled },
            set: { on in
                audioPolicy.overrides = on
                    ? AudioPolicy.smartDefaultOverrides()
                    : [:]
            }
        )
    }

    /// A dropdown binding for one category's audio-language preference, falling
    /// back to the base preference when no override is stored yet.
    private func audioPreferenceBinding(for category: ContentCategory) -> Binding<AudioLanguagePreference> {
        Binding(
            get: { audioPolicy.overrides[category] ?? playback.settings.audioLanguagePreference },
            set: { audioPolicy.overrides[category] = $0 }
        )
    }

    /// A native pop-up menu for choosing an audio-language preference (the
    /// common-language list is too long for the inline pill picker).
    @ViewBuilder
    private func audioLanguageMenu(_ selection: Binding<AudioLanguagePreference>) -> some View {
        Menu {
            Picker("Audio language", selection: selection) {
                ForEach(Self.audioPreferenceOptions, id: \.self) { preference in
                    Text(Self.audioPreferenceName(preference)).tag(preference)
                }
            }
        } label: {
            Label(Self.audioPreferenceName(selection.wrappedValue), systemImage: "globe")
        }
        .menuStyle(.button)
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

                SettingsPanel(title: "Subtitles") {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledSettingRow("Default", labelWidth: 220) {
                            SettingsOptionPicker(
                                options: CaptionSettings.SubtitleMode.allCases,
                                selection: $captions.settings.subtitleMode,
                                title: { $0.displayName }
                            )
                        }

                        Divider()

                        Toggle("Different default subtitles for movies, TV shows, and anime", isOn: perContentTypeBinding)

                        if perContentTypeEnabled {
                            ForEach(Self.policyCategories, id: \.self) { category in
                                LabeledSettingRow(category.displayName, labelWidth: 220) {
                                    SettingsOptionPicker(
                                        options: CaptionSettings.SubtitleMode.allCases,
                                        selection: modeBinding(for: category),
                                        title: { $0.displayName }
                                    )
                                }
                            }
                        }

                        Divider()

                        Toggle("Remember subtitles per series", isOn: $playback.settings.rememberSubtitleTrackPerSeries)
                    }
                }

                SettingsPanel(title: "Audio Language") {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledSettingRow("Preferred language", labelWidth: 220) {
                            audioLanguageMenu($playback.settings.audioLanguagePreference)
                        }

                        Divider()

                        Toggle("Different default audio for movies, TV shows, and anime", isOn: audioPerContentTypeBinding)

                        if audioPerContentTypeEnabled {
                            ForEach(Self.policyCategories, id: \.self) { category in
                                LabeledSettingRow(category.displayName, labelWidth: 220) {
                                    audioLanguageMenu(audioPreferenceBinding(for: category))
                                }
                            }
                        }

                        Divider()

                        Toggle("Remember audio per series", isOn: $playback.settings.rememberAudioTrackPerSeries)
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
                title: "Skip Intervals (left/right on remote)"
            ) {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledSettingRow("Skip Backward", labelWidth: 220) {
                        SettingsOptionPicker(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipBackwardInterval,
                            title: { $0.title }
                        )
                    }

                    LabeledSettingRow("Skip Forward", labelWidth: 220) {
                        SettingsOptionPicker(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipForwardInterval,
                            title: { $0.title }
                        )
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