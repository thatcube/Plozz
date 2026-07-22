import CoreModels
import Foundation
import MetadataKit

// MARK: - Capability seams

/// The external metadata capabilities a share resolver needs, each abstracted so a
/// resolver receives them explicitly instead of reaching a process-wide singleton
/// (`ArtworkRouter.shared`, `OverviewRouter.shared`) or constructing a concrete
/// client itself. Tests substitute fakes without touching or mutating any global
/// router; the only place the process-wide shared implementations are named is the
/// `.production` composition boundary at the bottom of this file.

/// Resolves strong external ids (with provenance) for a title.
protocol ShareExternalIDResolving: Sendable {
    func sourcedExternalIDs(
        title: String,
        year: Int?,
        isAnime: Bool,
        isTV: Bool
    ) async -> [String: SourcedValue<String>]
}

/// Resolves sourced artwork of a given kind for a synthetic query item.
protocol ShareSourcedArtworkResolving: Sendable {
    func sourcedArtworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> SourcedValue<URL>?
}

/// Resolves a sourced overview for a synthetic query item.
protocol ShareSourcedOverviewResolving: Sendable {
    func sourcedOverview(for item: MediaItem) async -> SourcedValue<String>?
}

/// The subset of TheTVDB metadata resolution the TVDB share resolver depends on.
protocol ShareTVDBMetadataResolving: Sendable {
    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata?
    func resolve(
        titles: [String],
        year: Int?,
        isMovie: Bool,
        episodeHints: [SeriesEpisodeHint]
    ) async -> TVDBMetadata?
}

/// A cohesive bundle of the external capabilities a metadata pipeline factory needs
/// to construct and drive the share resolvers, plus the provider configuration used
/// to select between them.
struct ShareExternalMetadataClients: Sendable {
    let ids: any ShareExternalIDResolving
    let artwork: any ShareSourcedArtworkResolving
    let overview: any ShareSourcedOverviewResolving
    /// The current TheTVDB provider configuration; `.isConfigured` selects the TVDB
    /// tier over the keyless base.
    let tvdbConfig: @Sendable () -> TVDBConfig
    /// Builds a TVDB metadata client for a configuration (injected so tests never
    /// perform network I/O).
    let makeTVDBClient: @Sendable (TVDBConfig) -> any ShareTVDBMetadataResolving
    /// Builds the Step 5 capability pipeline the ``PipelineShareResolver`` drives.
    /// Injected so tests substitute a pipeline of fake providers; defaults to the
    /// production provider set (each result-cached + circuit-broken).
    let makePipeline: @Sendable () -> MetadataEnrichmentPipeline

    init(
        ids: any ShareExternalIDResolving,
        artwork: any ShareSourcedArtworkResolving,
        overview: any ShareSourcedOverviewResolving,
        tvdbConfig: @escaping @Sendable () -> TVDBConfig,
        makeTVDBClient: @escaping @Sendable (TVDBConfig) -> any ShareTVDBMetadataResolving,
        makePipeline: @escaping @Sendable () -> MetadataEnrichmentPipeline = {
            ProductionMetadataProviders.makePipeline()
        }
    ) {
        self.ids = ids
        self.artwork = artwork
        self.overview = overview
        self.tvdbConfig = tvdbConfig
        self.makeTVDBClient = makeTVDBClient
        self.makePipeline = makePipeline
    }
}

// MARK: - Production adapters (composition boundary)

/// Wraps the keyless id resolver.
private struct KeylessIDResolverClient: ShareExternalIDResolving {
    func sourcedExternalIDs(
        title: String,
        year: Int?,
        isAnime: Bool,
        isTV: Bool
    ) async -> [String: SourcedValue<String>] {
        await KeylessIDResolver().sourcedExternalIDs(
            title: title,
            year: year,
            isAnime: isAnime,
            isTV: isTV
        )
    }
}

/// Wraps the process-wide artwork router. This adapter is the *only* share-pipeline
/// site allowed to name `ArtworkRouter.shared`, so its persistent cache behaviour is
/// preserved while the resolvers stay free of the global.
private struct SharedArtworkRouterClient: ShareSourcedArtworkResolving {
    func sourcedArtworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> SourcedValue<URL>? {
        await ArtworkRouter.shared.sourcedArtworkURL(kind, for: item)
    }
}

/// Wraps the process-wide overview router (see `SharedArtworkRouterClient`).
private struct SharedOverviewRouterClient: ShareSourcedOverviewResolving {
    func sourcedOverview(for item: MediaItem) async -> SourcedValue<String>? {
        await OverviewRouter.shared.sourcedOverview(for: item)
    }
}

/// Adapts a concrete `TVDBClient` to `ShareTVDBMetadataResolving` (avoids a
/// retroactive conformance on the MetadataKit type).
private struct TVDBClientMetadataResolver: ShareTVDBMetadataResolving {
    let client: TVDBClient

    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata? {
        await client.resolve(byTVDBID: id, isMovie: isMovie)
    }

    func resolve(
        titles: [String],
        year: Int?,
        isMovie: Bool,
        episodeHints: [SeriesEpisodeHint]
    ) async -> TVDBMetadata? {
        await client.resolve(
            titles: titles,
            year: year,
            isMovie: isMovie,
            episodeHints: episodeHints
        )
    }
}

extension ShareExternalMetadataClients {
    /// The default app composition: keyless id resolver + the process-wide artwork
    /// and overview routers (preserving their persistent caches), TVDB configuration
    /// from the bundle/environment, and a real `TVDBClient` per configuration. This
    /// is the single boundary where the shared globals are referenced.
    static var production: ShareExternalMetadataClients {
        ShareExternalMetadataClients(
            ids: KeylessIDResolverClient(),
            artwork: SharedArtworkRouterClient(),
            overview: SharedOverviewRouterClient(),
            tvdbConfig: { TVDBConfig.resolved() },
            makeTVDBClient: { TVDBClientMetadataResolver(client: TVDBClient(config: $0)) }
        )
    }

    /// Production composition (Step 6) that layers a user-override enrichment config
    /// and a shared ``MetadataProviderRuntime`` onto the pipeline. `enrichmentConfig`
    /// is read per pipeline build, so a newly registered share picks up the latest
    /// merged override; `providerRuntime`, when present, shares one result cache +
    /// breaker set across shares so `AppShell` can surface them in diagnostics.
    ///
    /// `providerConfig` is likewise read per build so a user entering/removing their
    /// Step 9 TMDB BYOK key takes effect on the next share refresh without a relaunch;
    /// its default reproduces the built-in (Info.plist) TMDb access exactly.
    static func production(
        enrichmentConfig: @escaping @Sendable () -> MetadataEnrichmentConfig,
        providerConfig: @escaping @Sendable () -> MetadataProviderConfig = { .resolved() },
        providerRuntime: MetadataProviderRuntime?
    ) -> ShareExternalMetadataClients {
        ShareExternalMetadataClients(
            ids: KeylessIDResolverClient(),
            artwork: SharedArtworkRouterClient(),
            overview: SharedOverviewRouterClient(),
            tvdbConfig: { TVDBConfig.resolved() },
            makeTVDBClient: { TVDBClientMetadataResolver(client: TVDBClient(config: $0)) },
            makePipeline: {
                ProductionMetadataProviders.makePipeline(
                    providerConfig: providerConfig(),
                    enrichmentConfig: enrichmentConfig(),
                    runtime: providerRuntime
                )
            }
        )
    }
}

/// The Step 6 metadata composition inputs the app hands the share catalog
/// coordinator: how to build the enrichment config (with user overrides layered on
/// the Info.plist baseline) and an optional shared provider runtime for diagnostics.
///
/// The default value reproduces the Step 5 behaviour exactly (baseline config,
/// per-pipeline caches/breakers), so a coordinator constructed without this input is
/// unchanged.
public struct ShareMetadataComposition: Sendable {
    public var enrichmentConfig: @Sendable () -> MetadataEnrichmentConfig
    /// Step 9: how the TMDb tier is reached, read per pipeline build so a user's BYOK
    /// key (or its removal) applies on the next share refresh. Defaults to the built-in
    /// Info.plist resolution, so an app that doesn't wire BYOK is unchanged.
    public var providerConfig: @Sendable () -> MetadataProviderConfig
    public var providerRuntime: MetadataProviderRuntime?

    public init(
        enrichmentConfig: @escaping @Sendable () -> MetadataEnrichmentConfig = { .resolved() },
        providerConfig: @escaping @Sendable () -> MetadataProviderConfig = { .resolved() },
        providerRuntime: MetadataProviderRuntime? = nil
    ) {
        self.enrichmentConfig = enrichmentConfig
        self.providerConfig = providerConfig
        self.providerRuntime = providerRuntime
    }
}
