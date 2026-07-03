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
    @AppStorage(TransparencyPreference.storageKey) private var transparencyPreferenceRaw = TransparencyPreference.default.rawValue
    /// App-wide (global) navigation chrome — top bar vs. sidebar. Same
    /// un-namespaced `@AppStorage` key `MainTabView` reads to pick the tab style.
    @AppStorage(NavigationStyle.storageKey) private var navigationStyleRaw = NavigationStyle.default.rawValue

    private var transparencyPreference: TransparencyPreference {
        TransparencyPreference(rawValue: transparencyPreferenceRaw) ?? .default
    }

    private var navigationStyle: NavigationStyle {
        NavigationStyle(rawValue: navigationStyleRaw) ?? .default
    }

    var body: some View {
        SettingsSplitLayout(sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var musicPlayer = musicPlayer
        let transparencyBinding = Binding(
            get: { transparencyPreference },
            set: { transparencyPreferenceRaw = $0.rawValue }
        )
        let navigationBinding = Binding(
            get: { navigationStyle },
            set: { navigationStyleRaw = $0.rawValue }
        )

        return [
            SettingsSplitSection(id: "display", header: "Display", rows: [
                SettingsSplitRow(
                    id: "navigation",
                    title: "Navigation",
                    description: "How you move between Home, Search and the rest of the app.",
                ) {
                    DescribedSegmentedPicker(
                        options: NavigationStyle.allCases,
                        selection: navigationBinding,
                        title: { $0.displayName },
                        detail: { $0.detail }
                    )
                },
                SettingsSplitRow(
                    id: "theme",
                    title: "Theme",
                    description: "The overall light or dark appearance of the app.",
                ) {
                    SettingsOptionList(
                        options: AppTheme.allCases,
                        selection: $theme.theme,
                        icon: { $0.symbolName },
                        title: { $0.displayName }
                    )
                },
                SettingsSplitRow(
                    id: "transparency",
                    title: "Transparency",
                    description: "Liquid glass — translucent panels and cards. Turn off for solid backgrounds.",
                ) {
                    DescribedSegmentedPicker(
                        options: TransparencyPreference.allCases,
                        selection: transparencyBinding,
                        title: { $0.displayName },
                        detail: { $0.detail }
                    )
                }
            ]),
            SettingsSplitSection(id: "music", header: "Music Player", rows: [
                SettingsSplitRow(
                    id: "music-style",
                    title: "Style",
                    description: "How the now-playing music screen is presented.",
                ) {
                    SettingsOptionList(
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
                ) {
                    Toggle("Show track details", isOn: $musicPlayer.showTrackDetails)
                }
            ])
        ]
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
        SettingsSplitLayout(sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "hide-spoilers",
                title: "Hide spoilers for unwatched episodes",
                description: "Blur or replace episode thumbnails and keep titles and descriptions hidden until you finish an episode.",
            ) {
                Toggle("Hide spoilers", isOn: $spoilers.settings.isEnabled)
            }
        ]

        if spoilers.settings.isEnabled {
            rows.append(
                SettingsSplitRow(
                    id: "spoiler-mode",
                    title: "Mode",
                    description: modeExplanation,
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
            ) {
                Toggle("Hide ratings", isOn: $spoilers.settings.hideRatingsUntilWatched)
            }
        )

        return [SettingsSplitSection(id: "spoilers", header: "Spoiler Protection", rows: rows)]
    }
}
struct PlaybackDetailView: View {
    @Bindable var playback: PlaybackSettingsModel
    /// The profile base subtitle mode/language now lives in `SubtitleBehavior`
    /// (behaviour half of the retired `CaptionSettings`).
    @Bindable var subtitleBehavior: SubtitleBehaviorModel
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

    private func subtitleLanguageName(for code: String) -> String {
        guard !code.isEmpty else { return "Device Default" }
        return SubtitleLanguageCatalog.languages.first(where: { $0.code == code })?.name ?? code
    }

    // MARK: Audio-language policy helpers

    /// The selectable audio-language preferences for the dropdowns: Original /
    /// Device, then the shared common-language list.
    private static let audioPreferenceOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map { .language($0.code) }

    /// Human-readable label for an audio-language preference.
    private static func audioPreferenceName(_ preference: AudioLanguagePreference) -> String {
        switch preference {
        case .original: return "Original"
        case .device: return "Device"
        case .language(let code):
            return SubtitleLanguageCatalog.languages.first(where: { $0.code == code })?.name ?? code
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
        SettingsSplitLayout(sections: sections)
    }

    // MARK: - Split sections

    private var sections: [SettingsSplitSection] {
        [
            subtitlesSection,
            audioSection,
            skipIntrosSection,
            skipIntervalsSection,
            scrubbingSection,
            upNextSection
        ]
    }

    private var subtitlesSection: SettingsSplitSection {
        SettingsSplitSection(id: "subtitles", header: "Subtitles", rows: [
            SettingsSplitRow(
                id: "subtitle-default",
                title: "Show subtitles",
                description: "What Plozz does with subtitles when playback starts. You can still change them while watching."
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
                description: "The language Plozz prefers when auto-selecting or downloading subtitles.",
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
            ) {
                Toggle("Auto-download subtitles", isOn: $subtitleBehavior.settings.autoDownloadSubtitles)
            },
            SettingsSplitRow(
                id: "subtitle-remember",
                title: "Remember subtitles per series",
                description: "When you change the subtitle track while watching a series, reuse that choice for the rest of the series.",
            ) {
                Toggle("Remember per series", isOn: $playback.settings.rememberSubtitleTrackPerSeries)
            },
            SettingsSplitRow(
                id: "subtitle-style-note",
                title: "Subtitle appearance",
                description: "Font, size, colour, position and background are adjusted from the player while you watch — open the subtitle menu during playback to fine-tune the look with a live preview.",
            ) {
                Text("Adjust subtitle appearance from the player while watching, so you can see every change against the video in real time.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        ])
    }

    private var audioSection: SettingsSplitSection {
        SettingsSplitSection(id: "audio", header: "Audio Language", rows: [
            SettingsSplitRow(
                id: "audio-preferred",
                title: "Preferred language",
                description: "The audio language Plozz selects automatically when a title offers more than one.",
            ) {
                audioLanguageMenu($playback.settings.audioLanguagePreference)
            },
            SettingsSplitRow(
                id: "audio-per-type",
                title: "Different audio default per type",
                description: "Use a separate preferred audio language for each kind of content — for example original audio for anime but your device language elsewhere.",
            ) {
                SettingsRevealSection(
                    isOn: audioPerContentTypeBinding,
                    masterLabel: "Use per-type defaults",
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
            ) {
                Toggle("Remember per series", isOn: $playback.settings.rememberAudioTrackPerSeries)
            }
        ])
    }

    private var skipIntrosSection: SettingsSplitSection {
        SettingsSplitSection(id: "skip-intros", header: "Skip Intros & Credits", rows: [
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
        ])
    }

    private var skipIntervalsSection: SettingsSplitSection {
        SettingsSplitSection(id: "skip-intervals", header: "Remote", rows: [
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
                            title: { $0.title }
                        )
                    }
                    LabeledSettingRow("Forward") {
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

    private var scrubbingSection: SettingsSplitSection {
        SettingsSplitSection(id: "scrubbing", header: "Scrubbing", rows: [
            SettingsSplitRow(
                id: "seek-without-pausing",
                title: "Seek without pausing",
                description: playback.settings.seekWithoutPausing
                    ? "Swipe to scrub while a title is playing and it resumes the moment you land — faster, but a stray swipe can move your position."
                    : "You must pause before you can scrub — a swipe while playing won't seek or pause. Pause (Play/Pause, or center-press the scrubber), scrub, then press Play to resume. Prevents accidental seeks.",
            ) {
                Toggle("Seek without pausing", isOn: $playback.settings.seekWithoutPausing)
            }
        ])
    }

    private var upNextSection: SettingsSplitSection {
        SettingsSplitSection(id: "up-next", header: "Up Next", rows: [
            SettingsSplitRow(
                id: "show-up-next-card",
                title: "Show Up Next card",
                description: playback.settings.showUpNextCard
                    ? "During an episode's closing credits, show a card with the next episode so you can jump straight to it. Respects your Spoilers settings, and replaces the Skip Credits button when there's a next episode."
                    : "Don't show the Up Next card. Episode credits behave like everything else — Skip Credits (if enabled) and the usual auto-advance at the very end.",
            ) {
                Toggle("Show Up Next card", isOn: $playback.settings.showUpNextCard)
            }
        ])
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
    let title: (Option) -> String
    let detail: (Option) -> String

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
                .foregroundStyle(.secondary)
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
    let categoryName: (SubtitleContentCategory) -> String
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

            Text(describedMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.18), value: describedMode)
        }
    }
}

// MARK: - Home Display

/// The "Home Display" settings page: the app's card presentation controls
/// (Display Size + Card Style, moved here from Appearance so all Home-facing
/// display tuning lives together) plus the **Featured Hero** carousel controls.
///
/// The hero settings are per-profile (``HeroSettingsModel`` in the environment,
/// injected at the app root next to Display Size / Card Style). Every control
/// two-way binds the model, whose `didSet` persists + broadcasts the change so
/// the live Home carousel recomputes.
struct HomeDisplayDetailView: View {
    /// The discovered libraries (with kind + owning account), used to populate
    /// the Random-source library picker. Shared with the Your Libraries screen.
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    /// Home visibility, so the Random picker only offers libraries the profile
    /// actually shows on Home (matching the hero's own visible-library default).
    let homeVisibility: HomeLibraryVisibilityModel

    @Environment(HeroSettingsModel.self) private var hero
    @Environment(UIDensitySettingsModel.self) private var density
    @Environment(CardStyleSettingsModel.self) private var cardStyle

    var body: some View {
        SettingsSplitLayout(sections: sections)
    }

    /// The movie/series libraries the profile shows on Home, in a stable display
    /// order — the universe offered by the Random-source picker (other kinds
    /// aren't browsable as a random grid).
    private var randomEligibleLibraries: [AggregatedLibrary] {
        (discoveredLibraries.value ?? [])
            .filter { $0.library.kind == .movie || $0.library.kind == .series }
            .filter { homeVisibility.isVisible($0.key) }
            .sorted { lhs, rhs in
                if lhs.serverName != rhs.serverName { return lhs.serverName < rhs.serverName }
                return lhs.library.title.localizedCaseInsensitiveCompare(rhs.library.title) == .orderedAscending
            }
    }

    private var sections: [SettingsSplitSection] {
        @Bindable var density = density
        @Bindable var cardStyle = cardStyle
        @Bindable var hero = hero

        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "display-size",
                title: "Display Size",
                description: "Scales card size, columns and spacing across the app.",
            ) {
                SettingsOptionList(
                    options: UIDensity.allCases,
                    selection: $density.density,
                    icon: { $0.symbolName },
                    title: { $0.displayName }
                )
            },
            SettingsSplitRow(
                id: "card-style",
                title: "Card Style",
                description: "How media is shown in rows and grids.",
            ) {
                DescribedSegmentedPicker(
                    options: CardStyle.allCases,
                    selection: $cardStyle.style,
                    title: { $0.displayName },
                    detail: { $0.detail }
                )
            }
        ]

        var heroRows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "hero-enabled",
                title: "Featured Hero",
                description: "A cinematic, rotating spotlight at the top of Home, with a Continue Watching row tucked under its lower edge.",
            ) {
                Toggle("Show the featured hero", isOn: $hero.settings.isEnabled)
                    .toggleStyle(SettingsSwitchToggleStyle())
            }
        ]

        if hero.settings.isEnabled {
            heroRows.append(
                SettingsSplitRow(
                    id: "hero-sources",
                    title: "Sources",
                    description: "Which content feeds the hero. Enabled sources are interleaved into one rotating set.",
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(HeroSourceKind.allCases) { source in
                            Toggle(isOn: sourceBinding(source)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(source.displayName, systemImage: source.symbolName)
                                    Text(source.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(SettingsSwitchToggleStyle())
                        }
                    }
                }
            )
            heroRows.append(
                SettingsSplitRow(
                    id: "hero-items",
                    title: "Items",
                    description: "How many titles rotate through the hero.",
                ) {
                    LabeledSettingRow("Items in rotation") {
                        SettingsStepper(
                            options: Array(HeroSettings.maxItemsRange),
                            selection: $hero.settings.maxItems,
                            title: { "\($0)" }
                        )
                    }
                }
            )
            if hero.settings.isEnabled(.randomFromLibrary) {
                heroRows.append(randomLibrariesRow)
            }
            heroRows.append(
                SettingsSplitRow(
                    id: "hero-auto-advance",
                    title: "Auto-Advance",
                    description: "Automatically rotate to the next title after a few seconds. Rotation always pauses while the hero is focused.",
                ) {
                    VStack(alignment: .leading, spacing: 24) {
                        Toggle("Rotate automatically", isOn: $hero.settings.autoAdvance)
                            .toggleStyle(SettingsSwitchToggleStyle())
                        if hero.settings.autoAdvance {
                            LabeledSettingRow("Seconds per title") {
                                SettingsStepper(
                                    options: Array(HeroSettings.autoAdvanceRange),
                                    selection: $hero.settings.autoAdvanceSeconds,
                                    title: { "\($0)s" }
                                )
                            }
                        }
                    }
                }
            )
            heroRows.append(
                SettingsSplitRow(
                    id: "hero-trailers",
                    title: "Background Trailers",
                    description: "Play a muted trailer behind the hero when one is available. Fades in only once it's actually playing.",
                ) {
                    Toggle("Play trailers in the background", isOn: $hero.settings.trailersEnabled)
                        .toggleStyle(SettingsSwitchToggleStyle())
                }
            )
        }

        return [
            SettingsSplitSection(id: "display", header: "Display", rows: rows),
            SettingsSplitSection(id: "hero", header: "Featured Hero", rows: heroRows)
        ]
    }

    /// The Random-source library picker row: a checklist of the profile's
    /// movie/series libraries. An **empty** selection means "all visible
    /// libraries", so the row seeds every library as included and collapses back
    /// to the empty (= all) state whenever the user re-includes them all.
    private var randomLibrariesRow: SettingsSplitRow {
        @Bindable var hero = hero
        let libraries = randomEligibleLibraries
        return SettingsSplitRow(
            id: "hero-random-libraries",
            title: "Random Libraries",
            description: "Which libraries the Random source draws from. Leave all selected to use every library shown on Home.",
        ) {
            if libraries.isEmpty {
                Text("No movie or TV libraries are shown on this profile's Home yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(libraries) { library in
                        Toggle(isOn: randomLibraryBinding(for: library.key, universe: libraries)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.library.title)
                                Text(library.serverName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(SettingsSwitchToggleStyle())
                    }
                }
            }
        }
    }

    /// A binding that adds/removes `source` from the hero's ordered source list
    /// while keeping the canonical ``HeroSourceKind/allCases`` order (so the
    /// stored order is stable regardless of toggle sequence).
    private func sourceBinding(_ source: HeroSourceKind) -> Binding<Bool> {
        Binding(
            get: { hero.settings.sources.contains(source) },
            set: { isOn in
                let current = Set(hero.settings.sources)
                var next = current
                if isOn { next.insert(source) } else { next.remove(source) }
                hero.settings.sources = HeroSourceKind.allCases.filter { next.contains($0) }
            }
        )
    }

    /// A binding for one library in the Random picker. Empty stored set == "all",
    /// so toggling off while empty first materialises the full universe; toggling
    /// the last-missing one back on collapses to empty (= all) again.
    private func randomLibraryBinding(for key: String, universe: [AggregatedLibrary]) -> Binding<Bool> {
        let allKeys = Set(universe.map(\.key))
        return Binding(
            get: {
                let keys = hero.settings.randomLibraryKeys
                return keys.isEmpty || keys.contains(key)
            },
            set: { isOn in
                var keys = hero.settings.randomLibraryKeys.isEmpty
                    ? allKeys
                    : hero.settings.randomLibraryKeys
                if isOn { keys.insert(key) } else { keys.remove(key) }
                // Keep only still-valid keys, then collapse "everything" to the
                // empty (= all) sentinel so newly-added libraries stay included.
                keys.formIntersection(allKeys)
                hero.settings.randomLibraryKeys = (keys == allKeys) ? [] : keys
            }
        )
    }
}
#endif
