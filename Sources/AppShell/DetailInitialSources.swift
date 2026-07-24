import CoreModels

/// Builds the `initialSources` used to seed a detail `ItemDetailViewModel` from a
/// tapped `MediaItem`, enriching the item's own `sources` with the identity
/// index's resolved **library** copies.
///
/// This is the single reconciliation step that lets a Discover-backed item — most
/// notably a **Plex watchlist entry**, which carries a global Discover id and an
/// EMPTY `sources` array — open with a working server picker and loadable
/// episodes: the identity index maps it to the real library copies on the user's
/// servers. Discovery (not-in-library Seerr) items get no enrichment, exactly as
/// before, since they intentionally have no library source.
///
/// The tvOS Home/Search shells and the iOS shell all funnel through this so the
/// enrichment can't drift between platforms — the divergence that once let
/// watchlist → detail work on iOS but not tvOS.
func detailInitialSources(
    for item: MediaItem,
    isDiscovery: Bool,
    identitySources: (MediaItem) -> [MediaSourceRef]
) -> [MediaSourceRef] {
    let indexed = isDiscovery ? [] : identitySources(item)
    var seen = Set<String>()
    return (item.sources + indexed).filter { seen.insert($0.id).inserted }
}
