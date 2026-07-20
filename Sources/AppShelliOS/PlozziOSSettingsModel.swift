#if os(iOS)
import CoreModels
import Foundation

@MainActor
final class PlozziOSSettingsModel {
    let theme: ThemeSettingsModel
    let transparency: TransparencyPreferenceModel
    let cardStyle: CardStyleSettingsModel
    let density: UIDensitySettingsModel
    let watchIndicator: WatchStatusIndicatorSettingsModel
    let playback: PlaybackSettingsModel
    let subtitleBehavior: SubtitleBehaviorModel
    let subtitlePolicy: SubtitlePolicyModel
    let audioPolicy: AudioPolicyModel
    let subtitleStyle: SubtitleStyleModel
    let spoilers: SpoilerSettingsModel
    let nightShift: NightShiftSettingsModel
    let hero: HeroSettingsModel
    let heroBackground: HeroBackgroundSettingsModel
    let themeMusic: ThemeMusicSettingsModel
    let homeVisibility: HomeLibraryVisibilityModel
    let diagnostics: DiagnosticsSettingsModel

    init(namespace: String? = nil) {
        theme = ThemeSettingsModel(
            store: ThemeSettingsStore(namespace: namespace)
        )
        transparency = TransparencyPreferenceModel(
            store: TransparencyPreferenceStore(namespace: namespace)
        )
        cardStyle = CardStyleSettingsModel(
            store: CardStyleSettingsStore(namespace: namespace)
        )
        density = UIDensitySettingsModel(
            store: UIDensitySettingsStore(namespace: namespace)
        )
        watchIndicator = WatchStatusIndicatorSettingsModel(
            store: WatchStatusIndicatorSettingsStore(namespace: namespace)
        )
        playback = PlaybackSettingsModel(
            store: PlaybackSettingsStore(namespace: namespace)
        )
        subtitleBehavior = SubtitleBehaviorModel(
            store: SubtitleBehaviorStore(namespace: namespace)
        )
        subtitlePolicy = SubtitlePolicyModel(
            store: SubtitlePolicyStore(namespace: namespace)
        )
        audioPolicy = AudioPolicyModel(
            store: AudioPolicyStore(namespace: namespace)
        )
        subtitleStyle = SubtitleStyleModel(
            store: SubtitleStyleStore(namespace: namespace)
        )
        let scaleMigrationKey =
            "ios.subtitleBaseFontSize.v2.\(namespace ?? "default")"
        if !UserDefaults.standard.bool(forKey: scaleMigrationKey) {
            subtitleStyle.style.fontScale = 1
            UserDefaults.standard.set(true, forKey: scaleMigrationKey)
        }
        spoilers = SpoilerSettingsModel(
            store: SpoilerSettingsStore(namespace: namespace)
        )
        nightShift = NightShiftSettingsModel(
            store: NightShiftSettingsStore(namespace: namespace)
        )
        hero = HeroSettingsModel(
            store: HeroSettingsStore(namespace: namespace)
        )
        heroBackground = HeroBackgroundSettingsModel(
            store: HeroBackgroundSettingsStore(namespace: namespace)
        )
        themeMusic = ThemeMusicSettingsModel(
            store: ThemeMusicSettingsStore(namespace: namespace)
        )
        homeVisibility = HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(namespace: namespace)
        )
        diagnostics = DiagnosticsSettingsModel(
            store: DiagnosticsSettingsStore(namespace: namespace)
        )
    }
}
#endif
