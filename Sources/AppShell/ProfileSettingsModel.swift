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
    /// Mutually-exclusive hero background mode (off / trailer / theme music)
    /// plus the trailer mute preference.
    public private(set) var heroBackgroundModel: HeroBackgroundSettingsModel
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
    ///
    /// All 18 sub-models are uniformly injectable via optional parameters (defaulted
    /// to `nil`), so tests can seed any subset and production call sites — which pass
    /// none — build every model scoped to `namespace` exactly as before.
    public init(
        namespace ns: String?,
        subtitleBehaviorModel: SubtitleBehaviorModel? = nil,
        subtitleStyleModel: SubtitleStyleModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        playbackModel: PlaybackSettingsModel? = nil,
        subtitlePolicyModel: SubtitlePolicyModel? = nil,
        audioPolicyModel: AudioPolicyModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        themeMusicModel: ThemeMusicSettingsModel? = nil,
        heroBackgroundModel: HeroBackgroundSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        musicPlayerModel: MusicPlayerSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        uiDensityModel: UIDensitySettingsModel? = nil,
        cardStyleModel: CardStyleSettingsModel? = nil,
        watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel? = nil,
        navigationStyleModel: NavigationStyleSettingsModel? = nil,
        transparencyModel: TransparencyPreferenceModel? = nil,
        heroSettingsModel: HeroSettingsModel? = nil,
        nightShiftModel: NightShiftSettingsModel? = nil
    ) {
        // If the caller supplied any settings model, treat them all as injected
        // (test path) and don't rebuild them on profile switch. Otherwise build
        // them scoped to the active profile's namespace.
        let injected = subtitleBehaviorModel != nil || subtitleStyleModel != nil
            || spoilerModel != nil || playbackModel != nil
            || subtitlePolicyModel != nil || audioPolicyModel != nil
            || themeModel != nil || themeMusicModel != nil || heroBackgroundModel != nil
            || diagnosticsModel != nil
            || musicPlayerModel != nil || homeLibraryVisibilityModel != nil
            || uiDensityModel != nil || cardStyleModel != nil
            || watchStatusIndicatorModel != nil || navigationStyleModel != nil
            || transparencyModel != nil || heroSettingsModel != nil
            || nightShiftModel != nil
        self.usesInjectedModels = injected

        // Single source of truth for constructing all 18 sub-models: injected models
        // are used as-is, the rest are built scoped to `ns`. `rebuild(namespace:)`
        // funnels through the same builder so the two code paths can't drift.
        let models = Self.makeModels(
            namespace: ns,
            subtitleBehaviorModel: subtitleBehaviorModel,
            subtitleStyleModel: subtitleStyleModel,
            spoilerModel: spoilerModel,
            playbackModel: playbackModel,
            subtitlePolicyModel: subtitlePolicyModel,
            audioPolicyModel: audioPolicyModel,
            themeModel: themeModel,
            themeMusicModel: themeMusicModel,
            heroBackgroundModel: heroBackgroundModel,
            diagnosticsModel: diagnosticsModel,
            musicPlayerModel: musicPlayerModel,
            homeLibraryVisibilityModel: homeLibraryVisibilityModel,
            uiDensityModel: uiDensityModel,
            cardStyleModel: cardStyleModel,
            watchStatusIndicatorModel: watchStatusIndicatorModel,
            navigationStyleModel: navigationStyleModel,
            transparencyModel: transparencyModel,
            heroSettingsModel: heroSettingsModel,
            nightShiftModel: nightShiftModel
        )
        self.subtitleBehaviorModel = models.subtitleBehaviorModel
        self.subtitleStyleModel = models.subtitleStyleModel
        self.spoilerModel = models.spoilerModel
        self.playbackModel = models.playbackModel
        self.subtitlePolicyModel = models.subtitlePolicyModel
        self.audioPolicyModel = models.audioPolicyModel
        self.themeModel = models.themeModel
        self.themeMusicModel = models.themeMusicModel
        self.heroBackgroundModel = models.heroBackgroundModel
        self.diagnosticsModel = models.diagnosticsModel
        self.musicPlayerModel = models.musicPlayerModel
        self.homeLibraryVisibilityModel = models.homeLibraryVisibilityModel
        self.uiDensityModel = models.uiDensityModel
        self.cardStyleModel = models.cardStyleModel
        self.watchStatusIndicatorModel = models.watchStatusIndicatorModel
        self.navigationStyleModel = models.navigationStyleModel
        self.transparencyModel = models.transparencyModel
        self.heroSettingsModel = models.heroSettingsModel
        self.nightShiftModel = models.nightShiftModel
    }

    /// Rebuilds the settings models scoped to the active profile's namespace.
    /// No-op when settings models were injected (tests).
    public func rebuild(namespace ns: String?) {
        guard !usesInjectedModels else { return }
        // Build a fresh set (no injected models) via the shared builder, so this
        // path stays byte-identical to `init`'s non-injected construction.
        let models = Self.makeModels(namespace: ns)
        subtitleBehaviorModel = models.subtitleBehaviorModel
        subtitleStyleModel = models.subtitleStyleModel
        spoilerModel = models.spoilerModel
        playbackModel = models.playbackModel
        subtitlePolicyModel = models.subtitlePolicyModel
        audioPolicyModel = models.audioPolicyModel
        themeModel = models.themeModel
        themeMusicModel = models.themeMusicModel
        heroBackgroundModel = models.heroBackgroundModel
        diagnosticsModel = models.diagnosticsModel
        musicPlayerModel = models.musicPlayerModel
        homeLibraryVisibilityModel = models.homeLibraryVisibilityModel
        uiDensityModel = models.uiDensityModel
        cardStyleModel = models.cardStyleModel
        watchStatusIndicatorModel = models.watchStatusIndicatorModel
        navigationStyleModel = models.navigationStyleModel
        transparencyModel = models.transparencyModel
        heroSettingsModel = models.heroSettingsModel
        nightShiftModel = models.nightShiftModel
    }

    /// Aggregate of the 18 per-profile sub-models, used to funnel `init` and
    /// `rebuild(namespace:)` through one construction path.
    private struct Models {
        var subtitleBehaviorModel: SubtitleBehaviorModel
        var subtitleStyleModel: SubtitleStyleModel
        var spoilerModel: SpoilerSettingsModel
        var playbackModel: PlaybackSettingsModel
        var subtitlePolicyModel: SubtitlePolicyModel
        var audioPolicyModel: AudioPolicyModel
        var themeModel: ThemeSettingsModel
        var themeMusicModel: ThemeMusicSettingsModel
        var heroBackgroundModel: HeroBackgroundSettingsModel
        var diagnosticsModel: DiagnosticsSettingsModel
        var musicPlayerModel: MusicPlayerSettingsModel
        var homeLibraryVisibilityModel: HomeLibraryVisibilityModel
        var uiDensityModel: UIDensitySettingsModel
        var cardStyleModel: CardStyleSettingsModel
        var watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel
        var navigationStyleModel: NavigationStyleSettingsModel
        var transparencyModel: TransparencyPreferenceModel
        var heroSettingsModel: HeroSettingsModel
        var nightShiftModel: NightShiftSettingsModel
    }

    /// The single source of truth for constructing the per-profile sub-models: each
    /// model uses the injected instance when supplied, otherwise a fresh one scoped
    /// to `ns`. Adding or removing a setting means editing only this list.
    private static func makeModels(
        namespace ns: String?,
        subtitleBehaviorModel: SubtitleBehaviorModel? = nil,
        subtitleStyleModel: SubtitleStyleModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        playbackModel: PlaybackSettingsModel? = nil,
        subtitlePolicyModel: SubtitlePolicyModel? = nil,
        audioPolicyModel: AudioPolicyModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        themeMusicModel: ThemeMusicSettingsModel? = nil,
        heroBackgroundModel: HeroBackgroundSettingsModel? = nil,
        diagnosticsModel: DiagnosticsSettingsModel? = nil,
        musicPlayerModel: MusicPlayerSettingsModel? = nil,
        homeLibraryVisibilityModel: HomeLibraryVisibilityModel? = nil,
        uiDensityModel: UIDensitySettingsModel? = nil,
        cardStyleModel: CardStyleSettingsModel? = nil,
        watchStatusIndicatorModel: WatchStatusIndicatorSettingsModel? = nil,
        navigationStyleModel: NavigationStyleSettingsModel? = nil,
        transparencyModel: TransparencyPreferenceModel? = nil,
        heroSettingsModel: HeroSettingsModel? = nil,
        nightShiftModel: NightShiftSettingsModel? = nil
    ) -> Models {
        Models(
            subtitleBehaviorModel: subtitleBehaviorModel ?? SubtitleBehaviorModel(store: SubtitleBehaviorStore(namespace: ns)),
            subtitleStyleModel: subtitleStyleModel ?? SubtitleStyleModel(store: SubtitleStyleStore(namespace: ns)),
            spoilerModel: spoilerModel ?? SpoilerSettingsModel(store: SpoilerSettingsStore(namespace: ns)),
            playbackModel: playbackModel ?? PlaybackSettingsModel(store: PlaybackSettingsStore(namespace: ns)),
            subtitlePolicyModel: subtitlePolicyModel ?? SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: ns)),
            audioPolicyModel: audioPolicyModel ?? AudioPolicyModel(store: AudioPolicyStore(namespace: ns)),
            themeModel: themeModel ?? ThemeSettingsModel(store: ThemeSettingsStore(namespace: ns)),
            themeMusicModel: themeMusicModel ?? ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(namespace: ns)),
            heroBackgroundModel: heroBackgroundModel ?? HeroBackgroundSettingsModel(
                store: HeroBackgroundSettingsStore(namespace: ns)
            ),
            diagnosticsModel: diagnosticsModel ?? DiagnosticsSettingsModel(store: DiagnosticsSettingsStore(namespace: ns)),
            musicPlayerModel: musicPlayerModel ?? MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: ns)),
            homeLibraryVisibilityModel: homeLibraryVisibilityModel ?? HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(namespace: ns)),
            uiDensityModel: uiDensityModel ?? UIDensitySettingsModel(store: UIDensitySettingsStore(namespace: ns)),
            cardStyleModel: cardStyleModel ?? CardStyleSettingsModel(store: CardStyleSettingsStore(namespace: ns)),
            watchStatusIndicatorModel: watchStatusIndicatorModel ?? WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(namespace: ns)),
            navigationStyleModel: navigationStyleModel ?? NavigationStyleSettingsModel(store: NavigationStyleSettingsStore(namespace: ns)),
            transparencyModel: transparencyModel ?? TransparencyPreferenceModel(store: TransparencyPreferenceStore(namespace: ns)),
            heroSettingsModel: heroSettingsModel ?? HeroSettingsModel(store: HeroSettingsStore(namespace: ns)),
            nightShiftModel: nightShiftModel ?? NightShiftSettingsModel(store: NightShiftSettingsStore(namespace: ns))
        )
    }
}
