import Foundation
import CoreModels

/// The single, dedicated networking lane for all artwork *byte* downloads
/// (posters, backdrops, hero/title logos, studio logos, episode stills).
///
/// Artwork is background-ish, high-volume, and best-effort, so it must never
/// contend for connections with the user-blocking item/metadata fetches
/// (`plozzInteractive`) nor with cross-server enrichment (`plozzDefault`). Giving
/// artwork its own `URLSession` — hence its own HTTP connection pool — keeps a
/// burst of poster/still downloads from a season prewarm from queuing behind, or
/// starving, the foreground request the user is waiting on.
///
/// Timeouts are short and explicit (mirroring CoreNetworking/MetadataHTTP) so a
/// poster/logo download to a slow or unreachable host (a sleeping server, a dead
/// external-metadata CDN URL) can't hold one of the ~6 per-host connections for a
/// full minute and poison subsequent loads as the session ages.
public enum ArtworkSession {
    public static let memoryCapacityBytes = 64 * 1024 * 1024
    public static let diskCapacityBytes = 384 * 1024 * 1024

    public struct CacheUsage: Sendable {
        public let memoryBytes: Int
        public let diskBytes: Int
        public let memoryCapacityBytes: Int
        public let diskCapacityBytes: Int
    }

    private static let byteCache = URLCache(
        memoryCapacity: memoryCapacityBytes,
        diskCapacity: diskCapacityBytes,
        diskPath: "plozz-artwork"
    )

    public static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        // A bounded, dedicated *byte* cache. Foundation owns per-entry eviction;
        // Plozz owns the enforceable capacity and reports current usage.
        // Decoded images live in a capped
        // NSCache that evicts under memory pressure, so during fast horizontal
        // scroll on a large multi-server Home a card's decoded image can be
        // evicted; when the card scrolls back its art would otherwise re-fetch
        // over the network and flash a gray placeholder. URLSession.shared's tiny
        // default URLCache (~512KB on tvOS) made that re-fetch hit the network
        // almost every time. A large disk-backed byte cache lets the evicted image
        // re-decode from cached bytes instantly instead — no network, no gray flash.
        config.urlCache = byteCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    public static func cacheUsage() -> CacheUsage {
        CacheUsage(
            memoryBytes: byteCache.currentMemoryUsage,
            diskBytes: byteCache.currentDiskUsage,
            memoryCapacityBytes: byteCache.memoryCapacity,
            diskCapacityBytes: byteCache.diskCapacity
        )
    }

    /// Global cap on *concurrent background* artwork warms (season prewarm,
    /// loose-thumbnail prefetch). Foreground, on-screen artwork (`image(for:)`
    /// driven by a visible card / hero) is intentionally **not** gated by this —
    /// only opportunistic warming is, so a prewarm storm can't saturate the
    /// artwork pool and stall the art the user is currently looking at.
    ///
    /// Tuned for UX: high enough that idle browsing fills art quickly (4 parallel
    /// warms saturate most of the 6-connection pool), low enough that ≥2
    /// connections stay reserved for foreground hero/logo/still loads.
    public static let warmLimiter = ConcurrencyLimiter(limit: 4)

    /// Global cap on *concurrent live metadata resolutions* for grid cards whose
    /// provider art is missing (no baked-in posterURL) — chiefly a large, not-yet-
    /// enriched SMB library, where every card would otherwise fire a live TMDb/
    /// keyless *search* to resolve its poster. Unbounded, that flood saturated the
    /// metadata network pool and the (serialized) ArtworkRouter actor as you scrolled
    /// deeper, compounding into whole-app lag and slow detail opens. Bounding the
    /// grid path to a few concurrent resolutions keeps it a gentle background fill;
    /// foreground/detail art calls ArtworkRouter directly (NOT gated here), so they
    /// never queue behind the grid backlog. Same lesson as the SMB probe-storm fix.
    public static let artworkResolveLimiter = ConcurrencyLimiter(limit: 3)
}
