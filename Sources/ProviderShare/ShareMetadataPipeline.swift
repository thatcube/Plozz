import CoreModels

/// The local + external metadata workers for one account/store/session generation.
/// Grouped so the coordinator receives both from a single factory call and owns
/// only their lifecycle, not the concrete resolver/enricher construction policy.
struct ShareMetadataPipeline: Sendable {
    let external: ShareEnricher
    let local: ShareLocalMetadataEnricher
    let artwork: ShareLocalArtworkProbeWorker
}

/// Constructs a ``ShareMetadataPipeline`` for a share. Injected into the coordinator
/// so resolver selection and worker construction live behind a seam that tests can
/// replace with a fake pipeline (no concrete provider imports required).
protocol ShareMetadataPipelineFactory: Sendable {
    func makePipeline(
        store: ShareCatalogStore,
        accountKey: String,
        credentialRevision: CredentialRevision,
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
        credentialRevision: CredentialRevision,
        reporter: ShareScanReporter,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) -> ShareMetadataPipeline {
        let browser = ShareTransportBrowser(role: .metadata, sessionFactory: sessionFactory)
        return ShareMetadataPipeline(
            external: ShareEnricher(
                store: store,
                resolver: makeExternalResolver(),
                shareID: accountKey,
                reporter: reporter
            ),
            local: ShareLocalMetadataEnricher(store: store, browser: browser),
            artwork: ShareLocalArtworkProbeWorker(
                store: store,
                browser: browser,
                accountID: accountKey,
                credentialRevision: credentialRevision
            )
        )
    }

    /// The Step 5 external resolver: a single ``PipelineShareResolver`` over the
    /// capability pipeline. The pipeline's provider set already encodes the
    /// "TheTVDB-when-configured, keyless otherwise" behaviour as configuration (each
    /// source inert when unusable), so no per-config resolver selection is needed.
    /// Exposed (non-private) so a test can assert the selected type without a global.
    func makeExternalResolver() -> any ShareMetadataResolving {
        PipelineShareResolver(pipeline: clients.makePipeline())
    }
}
