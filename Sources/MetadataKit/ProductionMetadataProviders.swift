import Foundation
import CoreModels

/// Assembles the concrete external providers into the ordered set the
/// ``MetadataEnrichmentPipeline`` drives. This is the single composition boundary
/// where the real network-backed providers are named; everything above it works
/// against the ``MetadataEnrichmentProvider`` protocol, so tests inject fakes.
///
/// Provider inclusion is unconditional — a provider that isn't usable (TheTVDB or
/// TMDb unconfigured, a content-type mismatch) simply returns an empty enrichment,
/// which is cheaper and simpler than conditional wiring. Ordering, and whether a
/// source is primary/secondary/disabled, is data in ``MetadataEnrichmentConfig``.
public enum ProductionMetadataProviders {
    /// The default provider set. Wikidata/Wikipedia are confined to idle backlog via
    /// their policy so they never sit on the foreground path.
    public static func make(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved()
    ) -> [any MetadataEnrichmentProvider] {
        [
            TVDBEnrichmentProvider(client: TVDBClient(config: tvdbConfig)),
            TMDbEnrichmentProvider(provider: TMDbMetadataProvider(access: providerConfig.tmdb)),
            AniListEnrichmentProvider(client: AniListArtworkProvider()),
            TVmazeEnrichmentProvider(client: TVmazeClient()),
            ArtworkEnrichmentAdapter(
                id: .kitsu,
                capabilities: [.poster, .backdrop],
                provider: KitsuArtworkProvider()
            ),
            ArtworkEnrichmentAdapter(
                id: .wikidata,
                capabilities: [.poster, .backdrop, .logo],
                policy: .idleBacklogFallback,
                provider: WikidataArtworkProvider()
            ),
            ArtworkEnrichmentAdapter(
                id: .wikipedia,
                capabilities: [.poster, .backdrop, .logo],
                policy: .idleBacklogFallback,
                provider: WikipediaArtworkProvider()
            ),
        ]
    }

    /// A pipeline wired with the production provider set and the resolved ordering
    /// configuration.
    public static func makePipeline(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved(),
        enrichmentConfig: MetadataEnrichmentConfig = .resolved()
    ) -> MetadataEnrichmentPipeline {
        MetadataEnrichmentPipeline(
            providers: make(providerConfig: providerConfig, tvdbConfig: tvdbConfig),
            config: enrichmentConfig
        )
    }
}
