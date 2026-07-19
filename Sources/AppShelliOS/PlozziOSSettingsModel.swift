#if os(iOS)
import CoreModels

@MainActor
final class PlozziOSSettingsModel {
    let theme = ThemeSettingsModel()
    let cardStyle = CardStyleSettingsModel()
    let density = UIDensitySettingsModel()
    let watchIndicator = WatchStatusIndicatorSettingsModel()
    let playback = PlaybackSettingsModel()
    let subtitleBehavior = SubtitleBehaviorModel()
    let subtitleStyle = SubtitleStyleModel()
    let spoilers = SpoilerSettingsModel()
    let nightShift = NightShiftSettingsModel()
    let hero = HeroSettingsModel()
    let diagnostics = DiagnosticsSettingsModel()
}
#endif
