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
        SettingsSplitLayout(title: "Appearance", sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var musicPlayer = musicPlayer
        @Bindable var density = density
        let transparencyBinding = Binding(
            get: { transparencyPreference },
            set: { transparencyPreferenceRaw = $0.rawValue }
        )

        return [
            SettingsSplitSection(id: "display", header: "Display", rows: [
                SettingsSplitRow(
                    id: "theme",
                    title: "Theme",
                    description: "The overall light or dark appearance of the app.",
                    valueSummary: theme.theme.displayName
                ) {
                    SettingsOptionPicker(
                        options: AppTheme.allCases,
                        selection: $theme.theme,
                        icon: { $0.symbolName },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "display-size",
                    title: "Display Size",
                    description: "Scales card size, columns and spacing across the app.",
                    valueSummary: density.density.displayName
                ) {
                    SettingsOptionPicker(
                        options: UIDensity.allCases,
                        selection: $density.density,
                        icon: { $0.symbolName },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "transparency",
                    title: "Transparency",
                    description: "Liquid glass — translucent panels and cards. Turn off for solid backgrounds.",
                    valueSummary: transparencyPreference.displayName
                ) {
                    SettingsOptionPicker(
                        options: TransparencyPreference.allCases,
                        selection: transparencyBinding,
                        icon: { $0.symbolName },
                        title: { $0.displayName }
                    )
                }
            ]),
            SettingsSplitSection(id: "music", header: "Music Player", rows: [
                SettingsSplitRow(
                    id: "music-style",
                    title: "Style",
                    description: "How the now-playing music screen is presented.",
                    valueSummary: musicPlayer.appearance.displayName
                ) {
                    SettingsOptionPicker(
                        options: MusicPlayerAppearance.allCases,
                        selection: $musicPlayer.appearance,
                        icon: { $0.symbolName },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "music-track-details",
                    title: "Track details",
                    description: "Show album name, audio quality & lyrics source on the now-playing screen.",
                    valueSummary: musicPlayer.showTrackDetails ? "On" : "Off"
                ) {
                    Toggle("Show album name, audio quality & lyrics source", isOn: $musicPlayer.showTrackDetails)
                }
            ])
        ]
    }
}

struct CaptionsDetailView: View {
    @Bindable var captions: CaptionSettingsModel

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        SettingsSplitLayout(title: "Subtitle Style", sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var captions = captions

        var styleRows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "follows-system-style",
                title: "Use system subtitle style",
                description: "Defer entirely to the system subtitle style set in tvOS Accessibility settings. Turn this off to customise size, colour, background and edges below.",
                valueSummary: captions.settings.followsSystemStyle ? "On" : "Off"
            ) {
                Toggle("Use system subtitle style", isOn: $captions.settings.followsSystemStyle)
            }
        ]

        if !captions.settings.followsSystemStyle {
            styleRows.append(
                SettingsSplitRow(
                    id: "text-size",
                    title: "Text size",
                    description: "How large subtitle text appears, as a multiple of the default size.",
                    valueSummary: "\(Int(captions.settings.fontScale * 100))%",
                    indented: true
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        OptionCardRow(options: fontScales, selection: $captions.settings.fontScale) {
                            optionLabel("\(Int($0 * 100))%")
                        }
                        captionPreview
                    }
                }
            )
            styleRows.append(
                SettingsSplitRow(
                    id: "text-color",
                    title: "Text color",
                    description: "The fill colour used for subtitle text.",
                    valueSummary: colorName(for: captions.settings.textColor),
                    indented: true
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        OptionCardRow(options: textColorOptions, selection: $captions.settings.textColor) {
                            colorLabel($0)
                        }
                        captionPreview
                    }
                }
            )
            styleRows.append(
                SettingsSplitRow(
                    id: "background",
                    title: "Background",
                    description: "Opacity of the panel drawn behind subtitle text for legibility.",
                    valueSummary: captions.settings.backgroundColor.alpha == 0 ? "Off" : "\(Int(captions.settings.backgroundColor.alpha * 100))%",
                    indented: true
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        OptionCardRow(options: backgroundOpacities, selection: $captions.settings.backgroundColor.alpha) {
                            optionLabel($0 == 0 ? "Off" : "\(Int($0 * 100))%")
                        }
                        captionPreview
                    }
                }
            )
            styleRows.append(
                SettingsSplitRow(
                    id: "edge-style",
                    title: "Edge style",
                    description: "The outline or shadow applied to subtitle text to separate it from the picture.",
                    valueSummary: captions.settings.edgeStyle.displayName,
                    indented: true
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        OptionCardRow(
                            options: CaptionSettings.EdgeStyle.allCases,
                            selection: $captions.settings.edgeStyle
                        ) { optionLabel($0.displayName) }
                        captionPreview
                    }
                }
            )
        }

        let style = SettingsSplitSection(id: "style", header: nil, rows: styleRows)
        return [style]
    }

    // MARK: Option data

    private var textColorOptions: [CaptionSettings.RGBAColor] {
        CaptionSettings.RGBAColor.presets.map(\.color)
    }

    private func colorName(for color: CaptionSettings.RGBAColor) -> String {
        CaptionSettings.RGBAColor.presets.first(where: { $0.color == color })?.name ?? "Custom"
    }

    // MARK: Label helpers

    private func optionLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
    }

    private func colorLabel(_ color: CaptionSettings.RGBAColor) -> some View {
        VStack(spacing: 10) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1))
            Text(colorName(for: color)).font(.headline)
        }
    }

    /// Local live preview (mirrors CoreUI's `CaptionPreview`, which is internal to
    /// that module) so the style rows show the current look without touching the
    /// shared `CaptionSettingsCard`.
    private var captionPreview: some View {
        VStack {
            Spacer()
            Text("The quick brown fox")
                .font(.system(size: 32 * captions.settings.fontScale))
                .foregroundStyle(captions.settings.textColor.swiftUIColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(captions.settings.backgroundColor.swiftUIColor)
                .shadow(radius: captions.settings.edgeStyle == .dropShadow ? 4 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
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
        SettingsSplitLayout(title: "Spoiler Protection", sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "hide-spoilers",
                title: "Hide spoilers for unwatched episodes",
                description: "Blur or replace episode thumbnails and keep titles and descriptions hidden until you finish an episode.",
                valueSummary: spoilers.settings.isEnabled ? "On" : "Off"
            ) {
                Toggle("Hide spoilers for unwatched episodes", isOn: $spoilers.settings.isEnabled)
            }
        ]

        if spoilers.settings.isEnabled {
            rows.append(
                SettingsSplitRow(
                    id: "spoiler-mode",
                    title: "Mode",
                    description: modeExplanation,
                    valueSummary: spoilers.settings.mode.displayName,
                    indented: true
                ) {
                    SettingsOptionPicker(
                        options: SpoilerSettings.Mode.allCases,
                        selection: $spoilers.settings.mode,
                        title: { $0.displayName }
                    )
                }
            )
        }

        rows.append(
            SettingsSplitRow(
                id: "hide-ratings",
                title: "Hide ratings until watched",
                description: "Keeps IMDb, Rotten Tomatoes and other scores hidden on a movie or episode until you've finished it, so the ratings don't bias you beforehand. They appear once it's marked watched.",
                valueSummary: spoilers.settings.hideRatingsUntilWatched ? "On" : "Off"
            ) {
                Toggle("Hide ratings until watched", isOn: $spoilers.settings.hideRatingsUntilWatched)
            }
        )

        return [SettingsSplitSection(id: "spoilers", header: "Spoiler Protection", rows: rows)]
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

    // MARK: Subtitle-language helpers

    private var subtitleLanguageOptions: [String] {
        [""] + CaptionSettingsCard.subtitleLanguages.map(\.code)
    }

    private var subtitleLanguageSelection: Binding<String> {
        Binding(
            get: { captions.settings.preferredSubtitleLanguage ?? "" },
            set: { captions.settings.preferredSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private func subtitleLanguageName(for code: String) -> String {
        guard !code.isEmpty else { return "Device Default" }
        return CaptionSettingsCard.subtitleLanguages.first(where: { $0.code == code })?.name ?? code
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
        SettingsSplitLayout(title: "Playback", sections: sections)
    }

    // MARK: - Split sections

    private var sections: [SettingsSplitSection] {
        [
            subtitlesSection,
            audioSection,
            skipIntrosSection,
            skipIntervalsSection
        ]
    }

    private var subtitlesSection: SettingsSplitSection {
        SettingsSplitSection(id: "subtitles", header: "Subtitles", rows: [
            SettingsSplitRow(
                id: "subtitle-default",
                title: "Show subtitles",
                description: "How subtitles behave by default for everything you play — full subtitles, only forced passages, or off.",
                valueSummary: captions.settings.subtitleMode.displayName
            ) {
                SettingsSegmentedPicker(
                    options: CaptionSettings.SubtitleMode.allCases,
                    selection: $captions.settings.subtitleMode,
                    title: { $0.displayName }
                )
            },
            SettingsSplitRow(
                id: "subtitle-per-type",
                title: "Different subtitle default per type",
                description: "Use a separate subtitle default for each kind of content — for example forced-only on movies but full subtitles on anime.",
                valueSummary: perContentTypeEnabled ? "On" : "Off"
            ) {
                SettingsRevealSection(
                    isOn: perContentTypeBinding,
                    masterLabel: "Use a different default per content type",
                    revealedHeader: "Per Content Type"
                ) {
                    ForEach(Self.policyCategories, id: \.self) { category in
                        LabeledSettingRow(category.displayName) {
                            SettingsSegmentedPicker(
                                options: CaptionSettings.SubtitleMode.allCases,
                                selection: modeBinding(for: category),
                                title: { $0.displayName }
                            )
                        }
                    }
                }
            },
            SettingsSplitRow(
                id: "subtitle-language",
                title: "Subtitle language",
                description: "The language Plozz prefers when auto-selecting or downloading subtitles.",
                valueSummary: subtitleLanguageName(for: subtitleLanguageSelection.wrappedValue)
            ) {
                Menu {
                    Picker("Subtitle language", selection: subtitleLanguageSelection) {
                        ForEach(subtitleLanguageOptions, id: \.self) { code in
                            Text(subtitleLanguageName(for: code)).tag(code)
                        }
                    }
                } label: {
                    Label(subtitleLanguageName(for: subtitleLanguageSelection.wrappedValue), systemImage: "globe")
                }
                .menuStyle(.button)
            },
            SettingsSplitRow(
                id: "subtitle-auto-download",
                title: "Automatically download subtitles",
                description: "When an item has no suitable subtitle in your preferred language, Plozz asks the Jellyfin server to fetch the best match so every client benefits.",
                valueSummary: captions.settings.autoDownloadSubtitles ? "On" : "Off"
            ) {
                Toggle("Automatically download subtitles", isOn: $captions.settings.autoDownloadSubtitles)
            },
            SettingsSplitRow(
                id: "subtitle-remember",
                title: "Remember subtitles per series",
                description: "When you change the subtitle track while watching a series, reuse that choice for the rest of the series.",
                valueSummary: playback.settings.rememberSubtitleTrackPerSeries ? "On" : "Off"
            ) {
                Toggle("Remember subtitle choice per series", isOn: $playback.settings.rememberSubtitleTrackPerSeries)
            },
            SettingsSplitRow(
                id: "subtitle-style",
                title: "Subtitle style",
                description: "Adjust subtitle font, size and colours. These settings are also available from the player while you watch."
            ) {
                NavigationLink(value: SettingsRoute.captions) {
                    HStack(spacing: 12) {
                        Image(systemName: "captions.bubble")
                        Text("Open Subtitle Style")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.headline)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(PlozzSeasonTabStyle(isSelected: false))
            }
        ])
    }

    private var audioSection: SettingsSplitSection {
        SettingsSplitSection(id: "audio", header: "Audio Language", rows: [
            SettingsSplitRow(
                id: "audio-preferred",
                title: "Preferred language",
                description: "The audio language Plozz selects automatically when a title offers more than one.",
                valueSummary: Self.audioPreferenceName(playback.settings.audioLanguagePreference)
            ) {
                audioLanguageMenu($playback.settings.audioLanguagePreference)
            },
            SettingsSplitRow(
                id: "audio-per-type",
                title: "Different audio default per type",
                description: "Use a separate preferred audio language for each kind of content — for example original audio for anime but your device language elsewhere.",
                valueSummary: audioPerContentTypeEnabled ? "On" : "Off"
            ) {
                SettingsRevealSection(
                    isOn: audioPerContentTypeBinding,
                    masterLabel: "Use a different default per content type",
                    revealedHeader: "Per Content Type"
                ) {
                    ForEach(Self.policyCategories, id: \.self) { category in
                        LabeledSettingRow(category.displayName) {
                            audioLanguageMenu(audioPreferenceBinding(for: category))
                        }
                    }
                }
            },
            SettingsSplitRow(
                id: "audio-remember",
                title: "Remember audio per series",
                description: "When you change the audio track while watching a series, reuse that choice for the rest of the series.",
                valueSummary: playback.settings.rememberAudioTrackPerSeries ? "On" : "Off"
            ) {
                Toggle("Remember audio choice per series", isOn: $playback.settings.rememberAudioTrackPerSeries)
            }
        ])
    }

    private var skipIntrosSection: SettingsSplitSection {
        SettingsSplitSection(id: "skip-intros", header: "Skip Intros & Credits", rows: [
            SettingsSplitRow(
                id: "skip-intros-mode",
                title: "Skip Intros",
                description: playback.settings.skipIntros.detail
                    + "\n\nWhen your server has detected intro and credit markers, Plozz can show a Skip button — or skip for you automatically — during playback. Requires server-side markers — Plex Pass on Plex, or the Media Segments / Intro Skipper feature on Jellyfin.",
                valueSummary: playback.settings.skipIntros.title
            ) {
                SettingsSegmentedPicker(
                    options: SkipIntrosMode.allCases,
                    selection: $playback.settings.skipIntros,
                    title: { $0.title }
                )
            }
        ])
    }

    private var skipIntervalsSection: SettingsSplitSection {
        SettingsSplitSection(id: "skip-intervals", header: "Skip Intervals", rows: [
            SettingsSplitRow(
                id: "skip-intervals",
                title: "Skip Intervals",
                description: "How far the remote's left and right buttons jump during playback.",
                valueSummary: "\(playback.settings.skipBackwardInterval.title) / \(playback.settings.skipForwardInterval.title)"
            ) {
                VStack(alignment: .leading, spacing: 28) {
                    LabeledSettingRow("Skip Backward") {
                        SettingsStepper(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipBackwardInterval,
                            title: { $0.title }
                        )
                    }
                    LabeledSettingRow("Skip Forward") {
                        SettingsStepper(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipForwardInterval,
                            title: { $0.title }
                        )
                    }
                }
            }
        ])
    }
}
#endif