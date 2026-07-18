import CoreModels

/// The local + external metadata workers for one account/store/session generation.
/// Grouped so the coordinator receives both from a single factory call and owns
/// only their lifecycle, not the concrete resolver/enricher construction policy.
struct ShareMetadataPipeline: Sendable {
    let external: ShareEnricher
    let local: ShareLocalMetadataEnricher
}

/// Constructs a ``ShareMetadataPipeline`` for a share. Injected into the coordinator
/// so resolver selection and worker construction live behind a seam that tests can
/// replace with a fake pipeline (no concrete provider imports required).
protocol ShareMetadataPipelineFactory: Sendable {
    func makePipeline(
        store: ShareCatalogStore,
        accountKey: String,
        reporter: ShareScanReporter,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) -> ShareMetadataPipeline
}

/// The default factory: owns external resolver selection/construction (the exact
/// TVDB-when-configured, keyless-otherwise policy previously baked into the
/// coordinator) plus local metadata enricher construction. All external capabilities
/// are supplied through ``ShareExternalMetadataClients``, so the factory itself
/// touches no process-wide metadata router.
struct DefaultShareMetadataPipelineFactory: ShareMetadataPipelineFactory {
    let clients: ShareExternalMetadataClients

    func makePipeline(
        store: ShareCatalogStore,
        accountKey: String,
        reporter: ShareScanReporter,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) -> ShareMetadataPipeline {
        ShareMetadataPipeline(
            external: ShareEnricher(
                store: store,
                resolver: makeExternalResolver(),
                shareID: accountKey,
                reporter: reporter
            ),
            local: ShareLocalMetadataEnricher(store: store, sessionFactory: sessionFactory)
        )
    }

    /// The exact external resolver for the current provider configuration:
    /// `TVDBShareResolver` when TheTVDB is configured, otherwise `KeylessShareResolver`.
    /// Exposed (non-private) so a test can assert the selected class without a global.
    func makeExternalResolver() -> any ShareMetadataResolving {
        let config = clients.tvdbConfig()
        if config.isConfigured {
            return TVDBShareResolver(
                tvdb: clients.makeTVDBClient(config),
                idResolver: clients.ids,
                artworkResolver: clients.artwork,
                overviewResolver: clients.overview
            )
        }
        return KeylessShareResolver(
            idResolver: clients.ids,
            artworkResolver: clients.artwork,
            overviewResolver: clients.overview
        )
    }
}
