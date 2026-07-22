import CoreModels
import FeatureSettings
import MetadataKit

/// Builds the Step 6 metadata-settings dependency bundle from app state. Lives in
/// its own file so the MetadataKit baseline lookup (Info.plist provider roles/order)
/// stays out of `RootView`, which only needs to call this one method.
@MainActor
extension AppState {
    func makeMetadataSettingsDependencies() -> MetadataSettingsDependencies {
        // The build's baseline (Info.plist / code defaults) — the default single-list
        // order + which sources the build disables, so the UI can seed the list and
        // mark each provider "baseline" vs a user "Custom" override.
        let baseline = MetadataEnrichmentConfig.resolved()
        return MetadataSettingsDependencies(
            providers: metadataProviderSettingsModel,
            cacheBudget: cacheBudgetSettingsModel,
            tmdbKey: tmdbUserKeyModel,
            baselineOrder: baseline.order,
            baselineDisabled: baseline.disabledSources,
            diagnosticsSnapshot: { [mediaShare] in await mediaShare.metadataDiagnosticsSnapshot() },
            applyCacheBudgets: { [mediaShare] settings in await mediaShare.applyCacheBudgets(settings) },
            clearCaches: { [mediaShare] in await mediaShare.clearMetadataCaches() }
        )
    }
}
