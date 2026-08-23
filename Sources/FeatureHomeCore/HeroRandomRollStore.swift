import CoreModels
import Foundation

/// Holds the Random source's last server-shuffled draw so an unrelated hero
/// recomputation reuses it instead of rolling a completely new set of titles.
///
/// The hero re-curates whenever Home republishes — a silent re-aggregation, a
/// warmed identity index, a watch mutation, a finished share scan. None of those
/// are a request for different random picks, but each one used to fan a fresh
/// `SortField.random` page request out across every visible library on every
/// connected server, and then hand the carousel a different set of titles. With
/// several servers connected that is both the most expensive part of a
/// recomputation and the reason the hero's contents kept changing on their own.
///
/// So a draw is kept and reused while it is still current: same libraries, same
/// cap, younger than ``lifetime``. Anything that genuinely changes what Random
/// may draw from — the library selection, the carousel size, a profile/source
/// scope change, or simply time passing — rolls again.
///
/// An `actor` because the curator fetches its sources concurrently, and this has
/// to stay a single shared draw across those tasks rather than a per-task one.
public actor HeroRandomRollStore {
    /// What a draw is valid for. A change to any of these changes which titles
    /// the draw could have contained.
    public struct Key: Hashable, Sendable {
        public var libraries: [HeroRandomLibrary]
        public var limit: Int
        /// The Random provider filters out finished titles itself, so a draw made
        /// under one setting is not a valid answer under the other.
        public var hideWatched: Bool
        /// Whose servers the draw came from — the active profile. Part of the key
        /// rather than something callers must remember to invalidate: a scope
        /// change that happened to leave the resolved library list unchanged would
        /// otherwise keep serving the previous profile's titles, and an
        /// invalidation raced against the curation it triggers can lose.
        public var scope: String

        public init(
            libraries: [HeroRandomLibrary],
            limit: Int,
            hideWatched: Bool,
            scope: String = ""
        ) {
            self.libraries = libraries
            self.limit = limit
            self.hideWatched = hideWatched
            self.scope = scope
        }
    }

    /// How long a draw stays current.
    ///
    /// Long enough that the background refreshes a viewer never asked for reuse
    /// it — which is what keeps the carousel still while they browse — and short
    /// enough that sitting on Home does eventually surface different titles.
    /// A cold launch always draws fresh, since the store starts empty.
    public static let defaultLifetime: TimeInterval = 10 * 60

    private let lifetime: TimeInterval
    private var key: Key?
    private var items: [MediaItem] = []
    private var rolledAt = Date.distantPast
    /// Bumped by ``invalidate()`` so a draw already in flight when the hero's
    /// basis changed cannot land afterwards and repopulate the store.
    private var generation = 0
    /// Which request started most recently. A draw only caches if it is still the
    /// newest one: two curations with *different* keys genuinely race, and the
    /// slower/older one must not overwrite the newer one's answer.
    private var requestSeq = 0
    private var latestSeq = 0
    /// Draws currently being fetched, keyed so overlapping curations share one
    /// multi-server fan-out per key instead of each paying for their own. Keyed
    /// rather than single-slot: an A→B→A sequence would otherwise start a second
    /// A roll because B had replaced the only handle.
    private var inFlight: [Key: Task<[MediaItem], Never>] = [:]

    public init(lifetime: TimeInterval = HeroRandomRollStore.defaultLifetime) {
        self.lifetime = lifetime
    }

    /// The current draw for `key`, running `roll` only when there isn't one.
    ///
    /// An empty result is never kept: a library that momentarily failed to answer
    /// must not silence the Random source for the rest of the lifetime.
    public func items(
        for key: Key,
        now: Date = Date(),
        roll: @escaping @Sendable () async -> [MediaItem]
    ) async -> [MediaItem] {
        if let current = reusable(for: key, now: now) { return current }
        if let existing = inFlight[key] { return await existing.value }

        let startedGeneration = generation
        requestSeq &+= 1
        let startedSeq = requestSeq
        latestSeq = startedSeq
        let task = Task { await roll() }
        inFlight[key] = task
        // `Task {}` does not inherit cancellation, and the draw is a fan-out across
        // every visible library on every connected server. Without this, tearing
        // down a curation left that work running to completion — the caller's own
        // `Task.isCancelled` checks can't run until it returns.
        let rolled = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight[key] == task { inFlight[key] = nil }
        guard !rolled.isEmpty,
              generation == startedGeneration,
              latestSeq == startedSeq else { return rolled }
        self.key = key
        self.items = rolled
        self.rolledAt = now
        return rolled
    }

    /// Discards the draw, so the next curation rolls again. Used when the hero's
    /// whole basis changes (a different profile, a different set of servers).
    public func invalidate() {
        key = nil
        items = []
        rolledAt = .distantPast
        generation &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func reusable(for key: Key, now: Date) -> [MediaItem]? {
        guard self.key == key, !items.isEmpty else { return nil }
        guard now.timeIntervalSince(rolledAt) < lifetime else { return nil }
        return items
    }
}
