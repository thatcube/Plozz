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
}
