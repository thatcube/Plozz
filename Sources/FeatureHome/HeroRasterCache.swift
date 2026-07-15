import Foundation

/// The pure state machine behind the experimental hero foreground **raster
/// cache** (gated by `PLZHERO_RASTER_FOREGROUND`). It owns *which* slide has a
/// valid prepared artifact, whether a lookup is a HIT or MISS, a monotonic
/// **generation** used to invalidate everything on a set/settings change, and a
/// byte-budget LRU eviction that never drops a slide inside the current prepare
/// window.
///
/// It is intentionally UIImage-agnostic — it stores a fingerprint and an integer
/// `byteCost` per slide, not the pixels — so it is fully unit-testable off-device
/// and off the main actor. The owning `HeroForegroundRasterizer` keeps the actual
/// `UIImage`s in a parallel map and drops exactly the keys this core reports as
/// evicted/invalidated. Mutating methods therefore return the item ids whose
/// pixels the caller must release, so the two never drift.
struct HeroRasterCacheCore {
    /// Soft ceiling on total decoded snapshot bytes. Eviction runs after a store
    /// pushes past this, oldest-used first, but never evicts a protected
    /// (in-window) slide — so a bounded window (≤5 slots) is always resident even
    /// if that momentarily exceeds the budget.
    let byteBudget: Int

    private struct Entry {
        var fingerprint: HeroForegroundFingerprint
        var byteCost: Int
        var lastUsedTick: Int
    }

    private var entries: [String: Entry] = [:]
    private var tick = 0

    /// Monotonic generation. Every ``invalidateAll(reason:)`` bumps it; markers log
    /// the value so a capture can attribute a MISS burst to a real invalidation
    /// (set swap / settings change) rather than the cache underperforming.
    private(set) var generation = 0
    private(set) var totalBytes = 0
    private(set) var hits = 0
    private(set) var misses = 0

    init(byteBudget: Int) {
        self.byteBudget = max(0, byteBudget)
    }

    // MARK: - Lookup

    /// A HIT/MISS lookup used at the transition frame. Records the statistic and,
    /// on a HIT, marks the slide most-recently-used so eviction favours truly cold
    /// slides. A stored artifact whose fingerprint no longer matches is a MISS
    /// (stale content must never be shown).
    mutating func lookup(itemID: String, fingerprint: HeroForegroundFingerprint) -> Bool {
        tick += 1
        if var entry = entries[itemID], entry.fingerprint == fingerprint {
            entry.lastUsedTick = tick
            entries[itemID] = entry
            hits += 1
            return true
        }
        misses += 1
        return false
    }

    /// A side-effect-free HIT test for a view body (no stats, no LRU touch), so
    /// reading the cache during rendering can't perturb eviction ordering or
    /// double-count a transition's HIT.
    func contains(itemID: String, fingerprint: HeroForegroundFingerprint) -> Bool {
        entries[itemID]?.fingerprint == fingerprint
    }

    // MARK: - Mutation

    /// Stores/updates the artifact for `itemID`, then evicts oldest-used slides
    /// outside `window` until back under budget. Returns the ids whose pixels the
    /// caller must release (an old artifact for the same id that was replaced is
    /// *not* returned — the caller overwrites it).
    @discardableResult
    mutating func store(
        itemID: String,
        fingerprint: HeroForegroundFingerprint,
        byteCost: Int,
        window: [Int] = [],
        windowItemIDs: [String] = []
    ) -> [String] {
        tick += 1
        if let old = entries[itemID] { totalBytes -= old.byteCost }
        entries[itemID] = Entry(fingerprint: fingerprint, byteCost: max(0, byteCost), lastUsedTick: tick)
        totalBytes += max(0, byteCost)
        return evict(protecting: Set(windowItemIDs))
    }

    /// Drops a single slide's artifact (e.g. it left the window and the caller is
    /// trimming eagerly). Returns whether anything was removed.
    @discardableResult
    mutating func drop(itemID: String) -> Bool {
        guard let removed = entries.removeValue(forKey: itemID) else { return false }
        totalBytes -= removed.byteCost
        return true
    }

    /// Invalidates **everything** and bumps the generation — used when the curated
    /// slide set changes identity or a setting that affects every snapshot (theme,
    /// spoiler policy) flips. Returns all dropped ids so the caller releases their
    /// pixels. Generation-guarded prepare work in flight is thereby discarded when
    /// it tries to store against the old generation (see the rasterizer).
    @discardableResult
    mutating func invalidateAll(reason: String = "") -> [String] {
        generation += 1
        let dropped = Array(entries.keys)
        entries.removeAll()
        totalBytes = 0
        return dropped
    }

    /// Whether a fresh prepare for `itemID`+`fingerprint` is needed (nothing stored
    /// or the stored fingerprint is stale). Lets the prepare pass skip already-fresh
    /// slides cheaply without touching stats.
    func needsPreparation(itemID: String, fingerprint: HeroForegroundFingerprint) -> Bool {
        entries[itemID]?.fingerprint != fingerprint
    }

    // MARK: - Eviction

    private mutating func evict(protecting protected: Set<String>) -> [String] {
        guard totalBytes > byteBudget else { return [] }
        // Oldest-used first, but never a protected (in-window) slide.
        let candidates = entries
            .filter { !protected.contains($0.key) }
            .sorted { $0.value.lastUsedTick < $1.value.lastUsedTick }
        var evicted: [String] = []
        for (key, entry) in candidates {
            guard totalBytes > byteBudget else { break }
            entries.removeValue(forKey: key)
            totalBytes -= entry.byteCost
            evicted.append(key)
        }
        return evicted
    }

    // MARK: - Introspection (tests / markers)

    var count: Int { entries.count }
    var storedItemIDs: Set<String> { Set(entries.keys) }
}
