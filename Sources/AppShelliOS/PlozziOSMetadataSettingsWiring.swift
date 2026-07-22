#if os(iOS)
import CoreModels
import FeatureSettings
import MetadataKit

/// Builds the metadata-settings dependency bundle from the iOS app model. Mirrors
/// tvOS `AppState.makeMetadataSettingsDependencies()` so iPhone/iPad present the
/// same household-wide Metadata screen: the two `@Observable` settings models plus
/// the build baseline (Info.plist provider roles/order) and the runtime-forwarding
/// closures. Kept in its own file so the MetadataKit baseline lookup stays out of
/// the settings view.
@MainActor
extension PlozziOSAppModel {
    func makeMetadataSettingsDependencies() -> MetadataSettingsDependencies {
        let baseline = MetadataEnrichmentConfig.resolved()
        return MetadataSettingsDependencies(
            providers: metadataProviderSettingsModel,
            cacheBudget: cacheBudgetSettingsModel,
            tmdbKey: tmdbUserKeyModel,
            baselineOrder: baseline.order,
            baselineDisabled: baseline.disabledSources,
            diagnosticsSnapshot: { [mediaShareRuntime] in await mediaShareRuntime.metadataDiagnosticsSnapshot() },
            applyCacheBudgets: { [mediaShareRuntime] settings in await mediaShareRuntime.applyCacheBudgets(settings) },
            clearCaches: { [mediaShareRuntime] in await mediaShareRuntime.clearMetadataCaches() }
        )
    }
}
#endif
