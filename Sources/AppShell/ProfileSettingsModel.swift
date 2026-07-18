import Foundation
import Observation
import CoreModels

/// Per-profile settings facet extracted from `AppState`.
///
/// Owns the household **per-profile** settings sub-models — the ones rebuilt when
/// the active profile changes so switching profiles swaps the active
/// theme/spoiler/caption/diagnostics/… state cleanly. Grouping them here gives
/// views a narrow collaborator to depend on (`appState.profileSettings.themeModel`)
/// instead of widening `AppState`'s observable surface, which is what drove the
/// per-view Swift type-check regressions.
///
/// Each sub-model is itself `@Observable`, and this facet is `@MainActor
/// @Observable`, so observation semantics are identical to when these properties
/// lived directly on `AppState`: a view reading
/// `appState.profileSettings.themeModel.theme` is tracked exactly as before.
///
/// Lifecycle mirrors the previous `AppState.rebuildSettingsModels()`: when the
/// caller injects models (tests), they're used as-is and never rebuilt; otherwise
/// they're (re)built scoped to the active profile's namespace via `rebuild(namespace:)`.
@MainActor
@Observable
public final class ProfileSettingsModel {
    /// Subtitle behaviour + appearance split out of the retired `CaptionSettings`.
    /// Behaviour (mode / language / auto-download) is the policy base input;
    /// appearance (`SubtitleStyle`) is the persisted look. Rebuilt on profile switch.
    public private(set) var subtitleBehaviorModel: SubtitleBehaviorModel
    public private(set) var subtitleStyleModel: SubtitleStyleModel
    public private(set) var spoilerModel: SpoilerSettingsModel
    public private(set) var playbackModel: PlaybackSettingsModel
    /// Per-profile per-content-type subtitle policy overrides (forced-only on
    /// movies, full subs on anime, …). The profile base mode/language lives in
    /// `subtitleBehaviorModel`; this only owns the overrides. Rebuilt on profile switch.
    public private(set) var subtitlePolicyModel: SubtitlePolicyModel
    /// Per-profile per-content-type audio-language overrides ("original audio for
    /// anime, device language for everything else"). The profile base preference
    /// lives in `playbackModel`; this only owns the overrides. Rebuilt on profile
    /// switch, mirroring `subtitlePolicyModel`.
    public private(set) var audioPolicyModel: AudioPolicyModel
    public private(set) var themeModel: ThemeSettingsModel
    /// Opt-in background theme music for movie and series detail pages.
    public private(set) var themeMusicModel: ThemeMusicSettingsModel
    public private(set) var diagnosticsModel: DiagnosticsSettingsModel
    /// The full-screen music player's per-profile look + "show extra info"
    /// preference. Scoped per profile (rebuilt on profile switch) like the theme.
    public private(set) var musicPlayerModel: MusicPlayerSettingsModel
    /// Which discovered libraries appear on the unified Home (opt-out). Shared
    /// live between the Settings checklist and Home so toggles take effect
    /// without a reload, and scoped per profile (rebuilt on profile switch) so
    /// each profile keeps its own Home customization.
    public private(set) var homeLibraryVisibilityModel: HomeLibraryVisibilityModel
    /// The active profile's UI density (Compact / Standard / Spacious / Extra
    /// Large). Scaled into `PlozzMetrics` and injected into the environment at the
    /// app root, and rebuilt on profile switch like the other per-profile models.
    public private(set) var uiDensityModel: UIDensitySettingsModel
    /// The active profile's media card style (framed glass cards vs borderless
    /// artwork-only "posters"). Injected into the environment at the app root like
    /// `uiDensityModel`, and rebuilt on profile switch like the other per-profile
    /// models.
    public private(set) var cardStyleModel: CardStyleSettingsModel
    /// The active profile's watch-status indicator (a "watched" check badge vs an
    /// "unwatched" corner flag on media cards). Injected into the environment at
    /// the app root like `cardStyleModel`, and rebuilt on profile switch like the
    /// other per-profile models.
    public private(set) var watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel
    /// The active profile's navigation chrome (top bar vs. collapsible sidebar).
    /// Injected into the environment at the app root like `cardStyleModel`, and
    /// rebuilt on profile switch like the other per-profile models.
    public private(set) var navigationStyleModel: NavigationStyleSettingsModel
    /// The active profile's transparency (liquid-glass) preference. Injected into
    /// the environment at the app root like `cardStyleModel`, and rebuilt on
    /// profile switch. Its `.system` option still defers to the device
    /// Accessibility "Reduce Transparency" setting.
    public private(set) var transparencyModel: TransparencyPreferenceModel
    /// The active profile's Home hero (featured carousel) settings: which sources
    /// feed it, how many items, Random library scope, trailers, and auto-advance.
    /// Scoped per profile (rebuilt on profile switch) like `cardStyleModel`.
    public private(set) var heroSettingsModel: HeroSettingsModel
    /// The active profile's Night Shift (warm/dim screen tint) settings + live
    /// schedule. Scoped per profile (rebuilt on profile switch) like the theme;
    /// its overlay is installed at the app root in `RootView`.
    public private(set) var nightShiftModel: NightShiftSettingsModel

    /// True when settings models were injected by the caller (tests) and so must
    /// not be rebuilt on profile switch.
    public let usesInjectedModels: Bool

    /// Builds the per-profile settings facet. When the caller supplies any settings
    /// model, all models are treated as injected (test path) and never rebuilt on
    /// profile switch; otherwise they're built scoped to `namespace`.
    public init(
        namespace ns: String?,
        subtitleBehaviorModel: SubtitleBehaviorModel? = nil,
        subtitleStyleModel: SubtitleStyleModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        playbackModel: PlaybackSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        themeMusicModel: ThemeMusicSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        musicPlayerModel: MusicPlayerSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        uiDensityModel: UIDensitySettingsModel? = nil,
        cardStyleModel: CardStyleSettingsModel? = nil,
        watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel? = nil,
        navigationStyleModel: NavigationStyleSettingsModel? = nil,
        transparencyModel: TransparencyPreferenceModel? = nil,
        nightShiftModel: NightShiftSettingsModel? = nil
    ) {
        // If the caller supplied any settings model, treat them all as injected
        // (test path) and don't rebuild them on profile switch. Otherwise build
        // them scoped to the active profile's namespace.
        let injected = spoilerModel != nil
            || subtitleBehaviorModel != nil || subtitleStyleModel != nil
            || playbackModel != nil
            || themeModel != nil || themeMusicModel != nil || diagnosticsModel != nil
            || homeLibraryVisibilityModel != nil || musicPlayerModel != nil
            || uiDensityModel != nil
            || cardStyleModel != nil
            || watchStatusIndicatorModel != nil
            || navigationStyleModel != nil
            || transparencyModel != nil
            || nightShiftModel != nil
        self.usesInjectedModels = injected
        self.subtitleBehaviorModel = subtitleBehaviorModel ?? SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns))
        self.subtitleStyleModel = subtitleStyleModel ?? SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns))
        self.spoilerModel = spoilerModel ?? SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        self.playbackModel = playbackModel ?? PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns))
        self.subtitlePolicyModel = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns))
        self.audioPolicyModel = AudioPolicyModel(store: AudioPolicyStore(namespace: ns))
        self.themeModel = themeModel ?? ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        self.themeMusicModel = themeMusicModel
            ?? ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(namespace: ns))
        self.diagnosticsModel = diagnosticsModel ?? DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        self.musicPlayerModel = musicPlayerModel ?? MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        self.homeLibraryVisibilityModel = homeLibraryVisibilityModel
            ?? HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        self.uiDensityModel = uiDensityModel
            ?? UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
        self.cardStyleModel = cardStyleModel
            ?? CardStyleSettingsModel(store: CardStyleSettingsStore(namespace: ns))
        self.watchStatusIndicatorModel = watchStatusIndicatorModel
            ?? WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(namespace: ns))
        self.navigationStyleModel = navigationStyleModel
            ?? NavigationStyleSettingsModel(store: NavigationStyleSettingsStore(namespace: ns))
        self.transparencyModel = transparencyModel
            ?? TransparencyPreferenceModel(store: TransparencyPreferenceStore(namespace: ns))
        self.heroSettingsModel = HeroSettingsModel(store: HeroSettingsStore(namespace: ns))
        self.nightShiftModel = nightShiftModel
            ?? NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))
    }

    /// Rebuilds the settings models scoped to the active profile's namespace.
    /// No-op when settings models were injected (tests).
    public func rebuild(namespace ns: String?) {
        guard !usesInjectedModels else { return }
        subtitleBehaviorModel = SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns))
        subtitleStyleModel = SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns))
        spoilerModel = SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns))
        playbackModel = PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns))
        subtitlePolicyModel = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns))
        audioPolicyModel = AudioPolicyModel(store: AudioPolicyStore(namespace: ns))
        themeModel = ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns))
        themeMusicModel = ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(namespace: ns))
        diagnosticsModel = DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns))
        musicPlayerModel = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns))
        homeLibraryVisibilityModel = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns))
        uiDensityModel = UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns))
        cardStyleModel = CardStyleSettingsModel(store: CardStyleSettingsStore(namespace: ns))
        watchStatusIndicatorModel = WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(namespace: ns))
        navigationStyleModel = NavigationStyleSettingsModel(store: NavigationStyleSettingsStore(namespace: ns))
        transparencyModel = TransparencyPreferenceModel(store: TransparencyPreferenceStore(namespace: ns))
        heroSettingsModel = HeroSettingsModel(store: HeroSettingsStore(namespace: ns))
        nightShiftModel = NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))
    }
}
