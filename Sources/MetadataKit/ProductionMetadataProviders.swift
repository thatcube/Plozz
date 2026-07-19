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
    /// The sources in the default provider set, in construction order. Used to build
    /// the default ``MetadataProviderRuntime`` breaker map and to order diagnostics.
    public static let defaultSources: [MetadataSource] = [
        .tvdb, .tmdb, .anilist, .tvmaze, .kitsu, .wikidata, .wikipedia,
    ]

    /// The default provider set. Wikidata/Wikipedia are confined to idle backlog via
    /// their policy so they never sit on the foreground path. When `cache` is
    /// supplied, every provider is wrapped in a ``ResilientEnrichmentProvider`` — its
    /// own circuit breaker plus the shared, provider+version-namespaced result cache —
    /// so an outage in one source degrades gracefully to its cached/last-known data
    /// without affecting the others.
    ///
    /// When a shared ``MetadataProviderRuntime`` is supplied via `makePipeline`, its
    /// result cache and per-source breakers are used (so `AppShell` can sample them
    /// for diagnostics); otherwise each provider gets a fresh breaker and the passed
    /// `cache`, preserving the Step 5 default.
    public static func make(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved(),
        cache: ProviderResultCache? = nil,
        breakerPolicy: ProviderCircuitBreaker.Policy = ProviderCircuitBreaker.Policy(),
        breakers: [MetadataSource: ProviderCircuitBreaker] = [:]
    ) -> [any MetadataEnrichmentProvider] {
        let providers: [any MetadataEnrichmentProvider] = [
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
        guard let cache else { return providers }
        // Each provider gets an INDEPENDENT breaker so outages are isolated per
        // source. A shared runtime supplies stable per-source breakers (for
        // diagnostics); otherwise a fresh one is minted per provider.
        return providers.map {
            ResilientEnrichmentProvider(
                base: $0,
                breaker: breakers[$0.id] ?? ProviderCircuitBreaker(policy: breakerPolicy),
                cache: cache
            )
        }
    }

    /// A pipeline wired with the production provider set (each result-cached under its
    /// own namespace) and the resolved ordering configuration.
    ///
    /// Pass a shared ``MetadataProviderRuntime`` to reuse one result cache + breaker
    /// set across every share and expose them to diagnostics; omit it for the Step 5
    /// default (fresh per-pipeline cache/breakers).
    public static func makePipeline(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved(),
        enrichmentConfig: MetadataEnrichmentConfig = .resolved(),
        cache: ProviderResultCache = ProviderResultCache(),
        runtime: MetadataProviderRuntime? = nil
    ) -> MetadataEnrichmentPipeline {
        MetadataEnrichmentPipeline(
            providers: make(
                providerConfig: providerConfig,
                tvdbConfig: tvdbConfig,
                cache: runtime?.resultCache ?? cache,
                breakers: runtime?.breakers ?? [:]
            ),
            config: enrichmentConfig
        )
    }
}
