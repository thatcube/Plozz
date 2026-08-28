#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct AppearanceDetailView: View {
    /// The household's libraries + per-profile availability, needed by the
    /// navigation-arrangement pane. Passed in (rather than reached for) so this
    /// view stays a plain function of what Settings already resolved.
    let librariesScope: ProfileLibrariesScope
    /// Keeps the selected Appearance feature stable while navigation shell changes.
    let settingsNavigation: SettingsNavigationModel
    @Bindable var theme: ThemeSettingsModel
    /// Circadian Mode (night-warming) settings, folded in as sections here — it's
    /// a display concern, so it no longer earns its own top-level row.
    @Bindable var nightShift: NightShiftSettingsModel
    /// Spoiler-protection (hide unwatched episode art/titles/ratings). It's a
    /// content-protection concern that applies wherever you browse — not
    /// Home-specific — so it lives here in Appearance rather than folded into Home.
    @Bindable var spoilers: SpoilerSettingsModel
    @Environment(MusicPlayerSettingsModel.self) private var musicPlayer
    /// App-wide card presentation — scale + style — that applies across every row
    /// and grid in the app (not just Home), so it lives in Appearance rather than
    /// Customize Home.
    @Environment(UIDensitySettingsModel.self) private var density
    @Environment(CardStyleSettingsModel.self) private var cardStyle
    @Environment(WatchStatusIndicatorSettingsModel.self) private var watchStatusIndicator
    /// Per-profile navigation chrome + transparency, edited here and injected into
    /// the environment by `MainTabView` (rebuilt on profile switch like the other
    /// per-profile appearance models).
    @Environment(NavigationStyleSettingsModel.self) private var navigation
    @Environment(TransparencyPreferenceModel.self) private var transparency
    @Environment(AppLanguageSettingsModel.self) private var appLanguage

    var body: some View {
        @Bindable var settingsNavigation = settingsNavigation
        SettingsSplitLayout(
            title: "Appearance",
            rows: rows,
            selection: $settingsNavigation.appearanceRowID
        )
            // Circadian's day/night preview animates a model flag; make sure it
            // never keeps running once you leave Appearance or turn Circadian off.
            .onChange(of: nightShift.settings.isEnabled) { _, enabled in
                if !enabled { nightShift.isPreviewing = false }
            }
            .onDisappear { nightShift.isPreviewing = false }
    }

    private var rows: [SettingsSplitRow] {
        @Bindable var musicPlayer = musicPlayer
        @Bindable var density = density
        @Bindable var navigation = navigation

        return [
                SettingsSplitRow(
                    id: "language",
                    title: "Language",
                    description: "The language Plozz uses for its own labels. Media titles keep the language your server provides."
                ) {
                    AppLanguagePicker(model: appLanguage)
                },
                SettingsSplitRow(
                    id: "theme",
                    title: "Theme"
                ) {
                    themeAndTransparency
                },
                SettingsSplitRow(
                    id: "display-size",
                    title: "Display Size",
                    description: "Scales card size, columns and spacing across the app.",
                ) {
                    CompactDisplaySizePicker(selection: $density.density)
                },
                SettingsSplitRow(
                    id: "cards",
                    title: "Cards",
                    description: "How media cards look across the app.",
                ) {
                    cardsControls
                },
                SettingsSplitRow(
                    id: "navigation",
                    title: "Navigation"
                ) {
                    NavigationAppearanceDetail(
                        navigation: navigation,
                        librariesScope: librariesScope
                    )
                },
                SettingsSplitRow(
                    id: "music-player",
                    title: "Music Player",
                    description: "How the now-playing music screen looks.",
                ) {
                    MusicPlayerStyleDetail(
                        appearance: $musicPlayer.appearance,
                        showTrackDetails: $musicPlayer.showTrackDetails
                    )
                }
        ] + CircadianRowsBuilder(model: nightShift).rows
            + SpoilerRowsBuilder(spoilers: spoilers).rows
    }

    /// Theme cards plus the transparency (liquid-glass) control folded in beneath
    /// them — transparency isn't a top-level concern, so it rides along in the
    /// "overall look" pane rather than owning a row. Its self-explanatory label +
    /// the tri-toggle's focus-following subtext carry the meaning, so it needs no
    /// separate description paragraph.
    @ViewBuilder private var themeAndTransparency: some View {
        @Bindable var transparency = transparency
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            CompactThemePicker(selection: $theme.theme)
            SettingsDetailGroup(title: "Liquid Glass") {
                DescribedSegmentedPicker(
                    options: TransparencyPreference.allCases,
                    selection: $transparency.preference,
                    title: { $0.displayName },
                    detail: { $0.detail }
                )
            }
        }
    }

    /// The media-card controls in one pane — style (framed vs poster), the
    /// watched indicator, and what focus does to a card — since all three are
    /// "how a card looks". Shorter swatches so the preview rows sit together
    /// without heavy scrolling; each headed by a shared uppercase section header.

    /// Everything controlled by the single Navigation master row.
    ///
    /// Style and its library arrangement belong together: changing to either
    /// leading-edge style reveals the shared ordered/hidden list directly beneath
    /// the picker. Top bar has no library destinations, so that section disappears.
    private struct NavigationAppearanceDetail: View {
        @Bindable var navigation: NavigationStyleSettingsModel
        let librariesScope: ProfileLibrariesScope

        var body: some View {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                CompactNavigationPicker(selection: $navigation.style)

                if navigation.style != .tabBar {
                    SettingsDetailGroup(
                        title: "Navigation Libraries",
                        description: "Choose which libraries appear in the navigation, and the order they appear in."
                    ) {
                        NavigationLibrariesDetailView(scope: librariesScope)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cardsControls: some View {
        @Bindable var cardStyle = cardStyle
        @Bindable var watchStatusIndicator = watchStatusIndicator
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsDetailGroup(title: "Style") {
                CompactCardStylePicker(selection: $cardStyle.style, swatchHeight: 150)
            }
            SettingsDetailGroup(title: "Watched Indicator") {
                CompactWatchIndicatorPicker(selection: $watchStatusIndicator.indicator, swatchHeight: 150)
            }
            SettingsDetailGroup(
                title: LocalizedStringResource(
                    "settings.cards.focus",
                    defaultValue: "Focus",
                    comment: "Section header in tvOS Settings > Appearance > Cards, above the picker that chooses what a media card does when the remote's focus lands on it. Not camera focus and not a concentration/Focus mode — this is the on-screen selection highlight."
                )
            ) {
                CompactCardFocusStylePicker(selection: $cardStyle.focusStyle, swatchHeight: 150)
            }
        }
    }
}

struct SpoilersDetailView: View {
    @Bindable var spoilers: SpoilerSettingsModel

    var body: some View {
        SettingsSplitLayout(title: "Spoilers", rows: SpoilerRowsBuilder(spoilers: spoilers).rows)
    }
}

/// Builds the Spoiler-protection settings rows. Extracted from
/// ``SpoilersDetailView`` so the same controls can appear folded into the
/// Appearance settings page (spoiler masking is a browsing concern that applies
/// everywhere, so it lives in Appearance rather than Home or its own row).
@MainActor
struct SpoilerRowsBuilder {
    let spoilers: SpoilerSettingsModel

    var rows: [SettingsSplitRow] {
        @Bindable var spoilers = spoilers
        return [
            SettingsSplitRow(
                id: "spoilers",
                title: "Spoilers",
                description: LocalizedStringResource(
                    "settings.spoilers.description",
                    defaultValue: "Hide unwatched episodes and ratings until you've seen them. Blurred ratings reveal when you press them.",
                    comment: "Description under the Spoilers heading in tvOS Settings, explaining what the switches below it do. 'Press' is the Apple TV remote's Select button."
                ),
            ) {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsRevealSection(
                        isOn: $spoilers.settings.isEnabled,
                        masterLabel: "Hide spoilers for unwatched episodes"
                    ) {
                        SettingsDetailGroup(title: "Mode") {
                            SpoilerModePicker(mode: $spoilers.settings.mode)
                        }
                    }

                    Toggle("Hide ratings until watched", isOn: $spoilers.settings.hideRatingsUntilWatched)
                        .toggleStyle(SettingsSwitchToggleStyle())
                }
            }
        ]
    }
}
/// Detail-page customization (a sibling to Customize Home): what plays behind the
/// hero on a movie/show detail page — static art, the trailer, or the title's
/// theme music. Kept separate from the Home hero (which lives in Customize Home)
/// and from Playback (which is video-playback behaviour).
struct DetailPageDetailView: View {
    @Bindable var themeMusic: ThemeMusicSettingsModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel

    var body: some View {
        SettingsSplitLayout(title: "Detail Page", rows: heroRows)
    }

    private var heroRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "detail-page-hero-mode",
                title: "Background",
                description: "Choose what plays behind the hero on a title's detail page. Trailer and theme music never play together."
            ) {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    DescribedSegmentedPicker(
                        options: HeroBackgroundMode.allCases,
                        selection: $heroBackground.settings.detailMode,
                        title: { $0.displayName },
                        detail: { $0.detail }
                    )
                    if heroBackground.settings.detailMode == .trailer {
                        Toggle("Start muted", isOn: $heroBackground.settings.detailTrailerMuted)
                    }
                    if heroBackground.settings.detailMode == .themeMusic {
                        SettingsDetailGroup(title: "Volume") {
                            DescribedSegmentedPicker(
                                options: ThemeMusicVolume.allCases,
                                selection: $themeMusic.settings.volume,
                                title: { $0.displayName },
                                detail: { $0.detail }
                            )
                        }
                    }
                }
            }
        ]
    }
}

struct PlaybackDetailView: View {
    @Environment(\.locale) private var locale
    @Bindable var playback: PlaybackSettingsModel
    /// The profile base subtitle mode/language now lives in `SubtitleBehavior`
    /// (behaviour half of the retired `CaptionSettings`).
    @Bindable var subtitleBehavior: SubtitleBehaviorModel
    /// Per-content-type overrides ("forced-only on movies, full subs on anime").
    @Bindable var subtitlePolicy: SubtitlePolicyModel
    /// Per-content-type audio-language overrides ("original audio for anime,
    /// device language for everything else").
    @Bindable var audioPolicy: AudioPolicyModel
    /// Whether the active profile has a server that can download subtitles
    /// (Jellyfin or Plex). A share-only profile can't — so the whole "Downloading
    /// subtitles" row (auto-download + SDH/Forced ranking, all of which only act on
    /// a server search) is hidden rather than shown as a dead control.
    var canDownloadSubtitles: Bool = true

    /// The three classifiable content types the per-type rules apply to, in the
    /// order shown in Settings (`.other` always follows the base, so it isn't
    /// shown as its own row).
    private static let policyCategories: [SubtitleContentCategory] = [.movie, .tvShow, .anime]

    /// Whether the profile has opted into per-content-type rules (any override set).
    private var perContentTypeEnabled: Bool { !subtitlePolicy.overrides.isEmpty }

    /// The profile base rule, derived live from the subtitle behaviour settings.
    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: subtitleBehavior.settings).basePolicy
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
    private func modeBinding(for category: SubtitleContentCategory) -> Binding<SubtitleMode> {
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
        [""] + SubtitleLanguageCatalog.languages.map(\.code)
    }

    private var subtitleLanguageSelection: Binding<String> {
        Binding(
            get: { subtitleBehavior.settings.preferredSubtitleLanguage ?? "" },
            set: { subtitleBehavior.settings.preferredSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private func subtitleLanguageName(for code: String) -> Text {
        guard !code.isEmpty else { return Text("Device Default") }
        return Text(
            verbatim: SubtitleLanguageCatalog.displayName(
                forCode: code,
                in: locale
            ) ?? code
        )
    }

    // MARK: Audio-language policy helpers

    /// The selectable audio-language preferences for the dropdowns: Original /
    /// Device, then the shared common-language list.
    private static let audioPreferenceOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map { .language($0.code) }

    /// Human-readable label for an audio-language preference.
    private func audioPreferenceName(
        _ preference: AudioLanguagePreference
    ) -> Text {
        switch preference {
        case .original: return Text("Original")
        case .device: return Text("Device")
        case .language(let code):
            return Text(
                verbatim: SubtitleLanguageCatalog.displayName(
                    forCode: code,
                    in: locale
                ) ?? code
            )
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
                    audioPreferenceName(preference).tag(preference)
                }
            }
        } label: {
            Label {
                audioPreferenceName(selection.wrappedValue)
            } icon: {
                Image(systemName: "globe")
            }
        }
        .menuStyle(.button)
    }

    var body: some View {
        SettingsSplitLayout(title: "Playback", rows: rows)
    }

    // MARK: - Split sections

    private var rows: [SettingsSplitRow] {
        subtitleRows
            + audioRows
            + skipIntroRows
            + skipIntervalRows
            + resumeRows
            + scrubbingRows
            + displayFadeRows
            + upNextRows
    }

    private var subtitleRows: [SettingsSplitRow] {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "subtitle-default",
                title: "Show subtitles",
                description: "What Plozz does with subtitles when playback starts."
            ) {
                SubtitleModeControl(
                    baseMode: $subtitleBehavior.settings.subtitleMode,
                    perTypeEnabled: perContentTypeBinding,
                    categories: Self.policyCategories,
                    categoryName: { $0.displayName },
                    categoryMode: { modeBinding(for: $0) }
                )
            },
            SettingsSplitRow(
                id: "subtitle-language",
                title: "Subtitle language",
                description: "The language Plozz prefers when choosing subtitles."
            ) {
                Menu {
                    Picker("Subtitle language", selection: subtitleLanguageSelection) {
                        ForEach(subtitleLanguageOptions, id: \.self) { code in
                            subtitleLanguageName(for: code).tag(code)
                        }
                    }
                } label: {
                    Label {
                        subtitleLanguageName(
                            for: subtitleLanguageSelection.wrappedValue
                        )
                    } icon: {
                        Image(systemName: "globe")
                    }
                }
                .menuStyle(.button)
            }
        ]

        // "Downloading subtitles" only makes sense with a server that can actually
        // fetch them (Jellyfin/Plex). A share-only profile can't download — it can
        // only use sidecar files already on the share — so hide the row entirely
        // rather than imply downloading works.
        if canDownloadSubtitles {
            rows.append(SettingsSplitRow(
                id: "subtitle-downloading",
                title: "Downloading subtitles",
                description: "Download subtitles you don't already have."
            ) {
                VStack(alignment: .leading, spacing: 28) {
                    Toggle("Automatically download", isOn: $subtitleBehavior.settings.autoDownloadSubtitles)
                    LabeledSettingRow("Hearing-Impaired (SDH)", trailingAlignment: .trailing) {
                        Menu {
                            Picker("Hearing-impaired subtitles", selection: $subtitleBehavior.settings.hearingImpairedPreference) {
                                ForEach(HearingImpairedPreference.allCases, id: \.self) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                        } label: {
                            Label(subtitleBehavior.settings.hearingImpairedPreference.displayName, systemImage: "ear")
                        }
                        .menuStyle(.button)
                    }
                    LabeledSettingRow("Forced", trailingAlignment: .trailing) {
                        Menu {
                            Picker("Forced subtitles", selection: $subtitleBehavior.settings.forcedSearchPreference) {
                                ForEach(ForcedSubtitlePreference.allCases, id: \.self) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                        } label: {
                            Label(subtitleBehavior.settings.forcedSearchPreference.displayName, systemImage: "captions.bubble")
                        }
                        .menuStyle(.button)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            })
        }

        rows.append(SettingsSplitRow(
            id: "subtitle-remember",
            title: "Remember subtitles per series",
            description: "Reuse the subtitle you pick for the rest of a series."
        ) {
            Toggle("Remember per series", isOn: $playback.settings.rememberSubtitleTrackPerSeries)
        })

        return rows
    }

    private var audioRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "audio-defaults",
                title: "Audio defaults",
                description: "How Plozz picks the audio language when a title offers more than one — with optional per-content-type rules and per-series memory.",
            ) {
                VStack(alignment: .leading, spacing: 32) {
                    LabeledSettingRow("Preferred language", trailingAlignment: .trailing) {
                        audioLanguageMenu($playback.settings.audioLanguagePreference)
                    }

                    SettingsRevealSection(
                        isOn: audioPerContentTypeBinding,
                        masterLabel: "Different default per type",
                        revealedHeader: "Per Content Type"
                    ) {
                        ForEach(Self.policyCategories, id: \.self) { category in
                            LabeledSettingRow(category.displayName, trailingAlignment: .trailing) {
                                audioLanguageMenu(audioPreferenceBinding(for: category))
                            }
                        }
                    }

                    Toggle("Remember audio per series", isOn: $playback.settings.rememberAudioTrackPerSeries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        ]
    }

    private var skipIntroRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "skip-intros-mode",
                title: "Skip Intros",
                description: "Uses intro and credit markers from your server. Requires Plex Pass on Plex, or Media Segments / Intro Skipper on Jellyfin.",
            ) {
                DescribedSegmentedPicker(
                    options: SkipIntrosMode.allCases,
                    selection: $playback.settings.skipIntros,
                    title: { $0.title },
                    detail: { $0.detail }
                )
            }
        ]
    }

    private var skipIntervalRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "skip-intervals",
                title: "Skip Intervals",
                description: "How far the remote's left and right buttons jump during playback.",
            ) {
                VStack(alignment: .leading, spacing: 28) {
                    LabeledSettingRow("Backward") {
                        SettingsStepper(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipBackwardInterval,
                            verbatimTitle: { $0.title(locale: locale) }
                        )
                    }
                    LabeledSettingRow("Forward") {
                        SettingsStepper(
                            options: SkipInterval.allCases,
                            selection: $playback.settings.skipForwardInterval,
                            verbatimTitle: { $0.title(locale: locale) }
                        )
                    }
                }
            }
        ]
    }

    private var resumeRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "resume-rewind",
                title: "Rewind on resume",
                description: "When you return to a partially-watched title, playback starts a little before where you left off. Set anywhere from 0 to 60 seconds.",
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsStepper(
                        options: ResumeRewindInterval.allCases,
                        selection: $playback.settings.resumeRewindInterval,
                        verbatimTitle: { $0.title(locale: locale) }
                    )
                    Text(playback.settings.resumeRewindInterval.effectDescription)
                        .font(.callout)
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        ]
    }

    private var scrubbingRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "seek-without-pausing",
                title: "Seek without pausing",
                description: playback.settings.seekWithoutPausing
                    ? "Swipe to scrub while a title is playing and it resumes the moment you land — faster, but a stray swipe can move your position."
                    : "You must pause before you can scrub — a swipe while playing won't seek or pause. Pause (Play/Pause, or center-press the scrubber), scrub, then press Play to resume. Prevents accidental seeks.",
            ) {
                Toggle("Seek without pausing", isOn: $playback.settings.seekWithoutPausing)
            }
        ]
    }

    /// Both display fades live in ONE row. They're the same idea — hide the blank
    /// your TV shows while it renegotiates the picture — and splitting them made
    /// the page imply a "Display Transitions" grouping the flat master list never
    /// renders. The toggles are labelled by what they cover, so they need no
    /// headers or per-toggle paragraphs above them.
    private var displayFadeRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "display-fades",
                title: "Fade on display changes",
                description: "If you don't match dynamic range or frame rate on your Apple TV, turn these off for faster transitions.",
            ) {
                VStack(alignment: .leading, spacing: 24) {
                    // "HDR" and "Dolby Vision" are both `neverTranslate` brands, so
                    // this label must reach the UI verbatim rather than entering the
                    // catalog where a translator would have no way to know that.
                    Toggle(isOn: $playback.settings.fadeOnDynamicRangeChange) {
                        Text(verbatim: "HDR & Dolby Vision")
                    }
                    Toggle("Frame rate", isOn: $playback.settings.fadeOnFrameRateChange)
                }
            }
        ]
    }

    /// Autoplay and the Up Next card, in that order: whether the next episode
    /// starts, then whether you're told about it first. They're independent (see
    /// ``PlaybackSettings/autoPlayNextEpisode``), so the card's own controls stay
    /// available with autoplay off — the card is still a one-press shortcut.
    private var upNextRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "autoplay-next-episode",
                title: "Autoplay",
                description: "Play the next episode automatically.",
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Autoplay next episode", isOn: $playback.settings.autoPlayNextEpisode)
                    Text(playback.settings.autoPlayNextEpisode
                         ? "The next episode starts when one finishes."
                         : "The player closes when an episode finishes.")
                        .font(.callout)
                        .plozzForeground(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            },
            SettingsSplitRow(
                id: "show-up-next-card",
                title: "Show Up Next card",
                description: "Jump straight to the next episode.",
            ) {
                VStack(alignment: .leading, spacing: 24) {
                    Toggle("Show Up Next card", isOn: $playback.settings.showUpNextCard)
                    if playback.settings.showUpNextCard {
                        LabeledSettingRow("Time before the end", subtitle: "When credits can't be detected") {
                            SettingsStepper(
                                options: PlaybackSettings.upNextLeadSecondsOptions,
                                selection: $playback.settings.upNextLeadSeconds,
                                verbatimTitle: { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow)) }
                            )
                        }
                    }
                }
            }
        ]
    }
}

/// A `SettingsSegmentedPicker` paired with a live description of what the
/// *focused* option does. Moving focus across the segments updates the line
/// beneath immediately — before you commit with Select — so each option's
/// behavior is explained as you browse, not only after you pick. When focus
/// isn't in the picker it falls back to describing the current selection.
private struct DescribedSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> LocalizedStringResource
    let detail: (Option) -> LocalizedStringResource

    @State private var focusedOption: Option?

    /// Focused option wins (live browsing); otherwise describe what's selected.
    private var describedOption: Option { focusedOption ?? selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSegmentedPicker(
                options: options,
                selection: $selection,
                title: title,
                onFocusedOptionChange: { focusedOption = $0 }
            )
            Text(detail(describedOption))
                .font(.callout)
                .plozzForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.18), value: describedOption)
    }
}

/// The unified "Show subtitles" control: a base Off / On / Forced Only tri-toggle
/// (the default for everything), an optional "different settings per type" reveal
/// exposing Movies / TV Shows / Anime tri-toggles, and a *single* live
/// description that follows focus across every tri-toggle. Off / On / Forced Only
/// mean the same thing wherever they appear, so one shared line explains the
/// focused option instead of repeating it four times; it falls back to the base
/// selection when focus is outside the pickers.
private struct SubtitleModeControl: View {
    @Binding var baseMode: SubtitleMode
    @Binding var perTypeEnabled: Bool
    let categories: [SubtitleContentCategory]
    let categoryName: (SubtitleContentCategory) -> LocalizedStringResource
    let categoryMode: (SubtitleContentCategory) -> Binding<SubtitleMode>

    /// The option currently under focus, plus which picker owns that focus. The
    /// owner check makes the shared line order-independent: a blur reported by
    /// one picker never clears focus that a sibling took in the same update.
    @State private var focusedMode: SubtitleMode?
    @State private var focusOwner: Int?

    private var describedMode: SubtitleMode { focusedMode ?? baseMode }

    /// `id` 0 is the base picker; the per-type pickers are `1...`.
    private func reportFocus(owner id: Int, mode: SubtitleMode?) {
        if let mode {
            focusOwner = id
            focusedMode = mode
        } else if focusOwner == id {
            focusOwner = nil
            focusedMode = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSegmentedPicker(
                options: SubtitleMode.allCases,
                selection: $baseMode,
                title: { $0.displayName },
                onFocusedOptionChange: { reportFocus(owner: 0, mode: $0) }
            )

            SettingsRevealSection(
                isOn: $perTypeEnabled,
                masterLabel: "Different for Movies, TV & Anime"
            ) {
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    LabeledSettingRow(categoryName(category)) {
                        SettingsSegmentedPicker(
                            options: SubtitleMode.allCases,
                            selection: categoryMode(category),
                            title: { $0.displayName },
                            onFocusedOptionChange: { reportFocus(owner: index + 1, mode: $0) }
                        )
                    }
                }
            }
            // Breathing room between the base "Show subtitles" picker and the
            // per-type override section below it.
            .padding(.top, 40)

            Text(describedMode.detail)
                .font(.callout)
                .plozzForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.18), value: describedMode)
        }
    }
}
#endif
