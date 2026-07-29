import CoreModels
import MetadataKit
import RatingsService

/// The single place both platform shells (tvOS `AppShell`, iOS `AppShelliOS`)
/// turn a tapped `MediaItem` into a fully-configured ``ItemDetailViewModel``.
///
/// Historically each navigation destination hand-rolled `ItemDetailViewModel(...)`
/// — ~7 near-identical call sites across two shells. When one platform gained a
/// reconciliation step (e.g. enriching `initialSources` from the identity index so
/// a Plex *watchlist* / Discover title resolves to its real library copies) and
/// the other didn't, the two silently diverged — which is how "open from
/// watchlist" worked on iOS but not tvOS. Routing every shell through this one
/// factory makes that class of divergence impossible: the item→viewModel glue
/// lives in exactly one place.
///
/// Each shell builds a `DetailOpenEnvironment` **once** from its own app model
/// (the closures below resolve providers, the identity index, cross-server
/// discovery, ratings, Seerr availability, and the snapshot cache), then every
/// destination calls ``makeViewModel(for:libraryOrigin:)`` /
/// ``makeSeriesContextViewModel(seriesID:seed:sourceAccountID:originAccountID:)``.
@MainActor
public struct DetailOpenEnvironment {
    /// Resolves an account id to its provider, falling back to a sensible primary
    /// when the id is unknown/nil (never optional — a detail page always needs a
    /// provider to load through).
    public let resolveProvider: (_ accountID: String?) -> any MediaProvider
    /// Resolves an account id to its provider, or nil when that account isn't
    /// active (used to fetch alternate-server copies).
    public let resolveOptionalProvider: @Sendable (_ accountID: String) -> (any MediaProvider)?
    /// Maps an item to the library `MediaSourceRef`s the identity index knows host
    /// it (keyed by the item's provider guids), so a Discover/watchlist item with
    /// empty `sources` still resolves to real library copies.
    public let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    /// Discovers *other servers* hosting the same title off the critical path, to
    /// fill the cross-server picker. `nil` disables cross-server discovery.
    public let crossServerSourceResolver: (@Sendable (MediaItem) async -> [MediaSourceRef])?
    /// External ratings (IMDb/RT/Metacritic) provider for live enrichment.
    public let ratingsProvider: any ExternalRatingsProviding
    /// Refreshes a discovery (Seerr) title's request/availability. `nil` when Seerr
    /// isn't wired.
    public let discoveryStatusRefresh: (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)?
    /// Builds the Related row's loader. A closure rather than a value because the
    /// loader holds per-page state, so each detail page needs its own.
    /// `nil` leaves the row absent.
    public let makeRelatedTitlesLoader: (@MainActor () -> RelatedTitlesLoader?)?
    /// Stale-while-revalidate detail snapshot cache (instant repaint on revisit).
    public let snapshotCache: DetailSnapshotCache

    public init(
        resolveProvider: @escaping (_ accountID: String?) -> any MediaProvider,
        resolveOptionalProvider: @escaping @Sendable (_ accountID: String) -> (any MediaProvider)?,
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        crossServerSourceResolver: (@Sendable (MediaItem) async -> [MediaSourceRef])?,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider(),
        discoveryStatusRefresh: (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)? = nil,
        makeRelatedTitlesLoader: (@MainActor () -> RelatedTitlesLoader?)? = nil,
        snapshotCache: DetailSnapshotCache = .ephemeral
    ) {
        self.resolveProvider = resolveProvider
        self.resolveOptionalProvider = resolveOptionalProvider
        self.identitySources = identitySources
        self.crossServerSourceResolver = crossServerSourceResolver
        self.ratingsProvider = ratingsProvider
        self.discoveryStatusRefresh = discoveryStatusRefresh
        self.makeRelatedTitlesLoader = makeRelatedTitlesLoader
        self.snapshotCache = snapshotCache
    }

    /// The `initialSources` to seed a detail view model from a tapped item: the
    /// item's own sources merged (deduped) with the identity index's resolved
    /// library copies. Discovery (not-in-library Seerr) items get no enrichment —
    /// they intentionally have no library source.
    ///
    /// Static so shells that build `ItemDetailViewModel` directly (iOS) share the
    /// exact merge rule rather than hand-rolling it, which would silently drift
    /// if the dedupe or ordering ever changed.
    public static func initialSources(
        for item: MediaItem,
        isDiscovery: Bool,
        identitySources: (MediaItem) -> [MediaSourceRef]
    ) -> [MediaSourceRef] {
        let indexed = isDiscovery ? [] : identitySources(item)
        var seen = Set<String>()
        return (item.sources + indexed).filter { seen.insert($0.id).inserted }
    }

    public func initialSources(for item: MediaItem, isDiscovery: Bool) -> [MediaSourceRef] {
        Self.initialSources(
            for: item,
            isDiscovery: isDiscovery,
            identitySources: identitySources
        )
    }

    /// Build the detail view model for a tapped movie or series — including a Plex
    /// **watchlist** / Discover title (empty `sources`, Discover id), which the
    /// identity-index enrichment above resolves to its real library copies so the
    /// server picker and episodes work.
    ///
    /// - Parameter libraryOrigin: soft tie-break for otherwise-equivalent sources;
    ///   locality and managed-server priority remain authoritative.
    public func makeViewModel(for item: MediaItem, libraryOrigin: String?) -> ItemDetailViewModel {
        let isDiscovery = item.isNotInLibraryDiscovery
        let sources = initialSources(for: item, isDiscovery: isDiscovery).map { source in
            guard let locality = resolveOptionalProvider(source.accountID)?.connectionLocality
            else { return source }
            var liveSource = source
            liveSource.locality = locality
            return liveSource
        }
        let selectedSource = isDiscovery
            ? nil
            : CrossSourceSelector.bestSelection(
                from: sources,
                capabilities: .detected(),
                preferring: libraryOrigin
            )?.source
        let selectedItem = selectedSource.map { item.selectingSource($0) } ?? item
        return ItemDetailViewModel(
            provider: resolveProvider(selectedSource?.accountID ?? item.sourceAccountID),
            itemID: selectedSource?.itemID ?? item.id,
            initialItem: selectedItem,
            isDiscoveryItem: isDiscovery,
            discoveryStatusRefresh: discoveryStatusRefresh,
            ratingsProvider: ratingsProvider,
            sourceAccountID: selectedSource?.accountID ?? item.sourceAccountID,
            originSourceAccountID: libraryOrigin,
            initialSources: sources,
            alternateProviderResolver: resolveOptionalProvider,
            crossServerSourceResolver: isDiscovery ? nil : crossServerSourceResolver,
            relatedTitlesLoader: makeRelatedTitlesLoader?(),
            snapshotCache: snapshotCache
        )
    }

    /// Build the detail view model for a series opened via an episode/season
    /// context: the fronted page IS the series, and the tapped child seeds the
    /// hero for instant first paint. No `initialSources` enrichment — the
    /// cross-server resolver fills the picker once the page settles, without ever
    /// switching the already-visible page automatically.
    public func makeSeriesContextViewModel(
        seriesID: String,
        seed: MediaItem,
        sourceAccountID: String?,
        originAccountID: String?
    ) -> ItemDetailViewModel {
        ItemDetailViewModel(
            provider: resolveProvider(sourceAccountID),
            itemID: seriesID,
            initialItem: seed,
            ratingsProvider: ratingsProvider,
            sourceAccountID: sourceAccountID,
            originSourceAccountID: originAccountID,
            alternateProviderResolver: resolveOptionalProvider,
            crossServerSourceResolver: crossServerSourceResolver,
            relatedTitlesLoader: makeRelatedTitlesLoader?(),
            snapshotCache: snapshotCache
        )
    }
}
