import CoreModels
import Foundation

/// Folds a freshly curated hero set into the one already on screen, instead of
/// replacing it.
///
/// A hero re-curation is triggered by things the viewer never asked for — a
/// silent Home re-aggregation, a warmed identity index, a watch mutation, a
/// share scan. Assigning its result wholesale made every one of those visible:
/// the carousel's contents changed under the viewer, the fronted slide often did
/// not survive, and the backdrop wiped to something else mid-browse. With many
/// servers connected that happened constantly, which is what made the hero feel
/// like it was permanently reloading.
///
/// The fix is to treat a re-curation as an **update to the live set**, not a new
/// set:
///
/// - Titles already on screen keep their **slot**; their payload is replaced by
///   the newer copy, so watch state, availability, a series' next episode and
///   metadata enrichment all still land.
/// - Titles the fresh curation no longer offers are **kept for a while**, not
///   dropped on sight. One re-roll not picking something again is not evidence it
///   is gone, and the viewer was already able to browse to it. Absence from
///   ``retentionGrace`` curations in a row *is* treated as evidence — that is
///   what retires deleted media, a title taken off the watchlist, or a library
///   the viewer just hid. It is also self-healing: if a server outage retired
///   something wrongly, the next good curation admits it straight back.
/// - Genuinely new titles are **admitted**: into spare capacity first, then over
///   the stalest retained slot once the carousel is full — never over a slide the
///   viewer is currently looking at.
/// - An empty fresh set is a failed refresh unless the caller can say otherwise
///   (`freshIsAuthoritative`), so a momentary outage leaves the carousel alone
///   while genuinely running out of content clears it.
///
/// Positions of everything else stay put, which is what makes the update
/// invisible: `HomeHeroView` re-seats by identity, so an unchanged fronted id
/// means no wipe, no re-paged dots and no restarted dwell.
///
/// Pure and shell-agnostic, so tvOS and iOS refresh their heroes identically.
public enum HeroLiveMerge {
    /// How many consecutive curations may fail to offer a title before it is
    /// treated as genuinely gone rather than merely not re-rolled.
    ///
    /// Low enough that a removed title does not haunt the carousel, high enough
    /// that a title survives the routine background refreshes the viewer never
    /// asked for.
    public static let retentionGrace = 3

    /// How many further curations a slide the viewer is looking at may hold a slot
    /// the fold wants to change, before it is changed anyway.
    ///
    /// Deferring while pinned is what stops the backdrop wiping under someone's
    /// eyes, but it cannot be absolute, because pinning does not always rotate:
    /// a one-slide carousel (`maxItems` goes down to 1) pins its only slot
    /// forever, and with auto-advance switched off the fronted slide never moves
    /// on its own. An absolute exemption freezes those heroes for the whole
    /// session — they would keep showing last launch's snapshot and never take a
    /// freshly curated title. Past this ceiling the change lands regardless.
    public static let pinnedDeferralLimit = 2

    public struct Outcome: Equatable, Sendable {
        /// The set to display.
        public var items: [MediaItem]
        /// Ids admitted by this merge (new titles).
        public var admitted: [String]
        /// Ids that left: evicted to make room, retained past their grace, or
        /// collapsed into a slide of the same title.
        public var retired: [String]
        /// How many consecutive curations have now failed to offer each retained
        /// title. Hand this back to the next merge.
        public var misses: [String: Int]

        public init(
            items: [MediaItem],
            admitted: [String] = [],
            retired: [String] = [],
            misses: [String: Int] = [:]
        ) {
            self.items = items
            self.admitted = admitted
            self.retired = retired
            self.misses = misses
        }

        /// Whether the displayed identity set changed at all. A merge that only
        /// refreshed payloads leaves the carousel completely undisturbed.
        public var changedIdentitySet: Bool {
            !admitted.isEmpty || !retired.isEmpty
        }
    }

    /// - Parameters:
    ///   - showing: what the hero is displaying right now, in carousel order.
    ///     Already watch-reconciled by the caller.
    ///   - fresh: the newly completed curation.
    ///   - limit: the viewer's configured carousel size (`HeroSettings.maxItems`).
    ///   - pinnedItemIDs: the slides on screen — the fronted one, plus whatever a
    ///     committed transition is landing on. These are never evicted, never
    ///     retired, and never swapped for a different record, because all three
    ///     would move the carousel under the viewer's eyes. They take the newer
    ///     record as soon as they are no longer pinned.
    ///   - misses: the previous outcome's `misses`.
    ///   - freshIsAuthoritative: whether an EMPTY `fresh` means "there is nothing
    ///     to show" rather than "a fetch failed". Only the caller can tell those
    ///     apart, and getting it wrong either blanks a good carousel or keeps a
    ///     dead one, so it has no safe default beyond "assume failure".
    public static func merge(
        showing: [MediaItem],
        fresh: [MediaItem],
        limit: Int,
        pinnedItemIDs: Set<String> = [],
        misses: [String: Int] = [:],
        freshIsAuthoritative: Bool = false
    ) -> Outcome {
        guard limit > 0 else { return Outcome(items: []) }
        guard !showing.isEmpty else {
            let admitted = Array(fresh.prefix(limit))
            return Outcome(items: admitted, admitted: admitted.map(\.id))
        }
        guard !fresh.isEmpty else {
            // A refresh that came back with nothing is normally a network blip,
            // not an empty library — the same rule `HomeViewModel.load` applies to
            // the rows — and proves nothing about any title, so nothing ages.
            guard freshIsAuthoritative else {
                return Outcome(items: Array(showing.prefix(limit)), misses: misses)
            }
            return Outcome(items: [], retired: showing.map(\.id))
        }

        // A slide only holds its slot against the fold for so long — see
        // `pinnedDeferralLimit`. Past the ceiling it stops counting as pinned, so
        // a carousel that never rotates still updates.
        let deferralCeiling = retentionGrace + pinnedDeferralLimit
        let effectivePinned = pinnedItemIDs.filter {
            (misses[$0] ?? 0) < deferralCeiling
        }

        let freshTokens = fresh.map { HeroDedupe.tokens(for: $0) }
        var claimed = [Bool](repeating: false, count: fresh.count)

        // 1. Every title already on screen holds its slot, taking the newer copy
        //    when the fresh curation still offers it. One that isn't offered ages;
        //    past its grace it is treated as gone.
        var merged: [MediaItem] = []
        merged.reserveCapacity(max(showing.count, limit))
        var nextMisses: [String: Int] = [:]
        var stalestFirst: [Int] = []
        var retired: [String] = []
        var placed: [Set<String>] = []
        for item in showing {
            let tokens = HeroDedupe.tokens(for: item)
            // Enrichment can reveal that two slides were always the same title.
            // One show gets one slide, so the duplicate goes rather than rendering
            // the same backdrop twice — dropping the copy the viewer is NOT
            // looking at.
            if let duplicate = placed.firstIndex(where: { !$0.isDisjoint(with: tokens) }) {
                guard effectivePinned.contains(item.id) else {
                    retired.append(item.id)
                    continue
                }
                // Both copies on screen at once is an iOS swipe mid-flight. Taking
                // either one out from under it strands the transition, so the
                // collapse waits for the swipe to finish.
                guard !effectivePinned.contains(merged[duplicate].id) else {
                    placed.append(tokens)
                    merged.append(item)
                    continue
                }
                retired.append(merged[duplicate].id)
                nextMisses[merged[duplicate].id] = nil
                merged.remove(at: duplicate)
                placed.remove(at: duplicate)
                stalestFirst = stalestFirst.compactMap {
                    $0 == duplicate ? nil : ($0 > duplicate ? $0 - 1 : $0)
                }
            }
            let match = fresh.indices.first {
                !claimed[$0] && !freshTokens[$0].isDisjoint(with: tokens)
            }
            if let match {
                claimed[match] = true
                let upgraded = refreshed(
                    item,
                    from: fresh[match],
                    isPinned: effectivePinned.contains(item.id)
                )
                placed.append(HeroDedupe.tokens(for: upgraded))
                merged.append(upgraded)
                continue
            }
            let missCount = (misses[item.id] ?? 0) + 1
            let ceiling = pinnedItemIDs.contains(item.id)
                ? deferralCeiling
                : retentionGrace
            guard missCount < ceiling else {
                retired.append(item.id)
                continue
            }
            nextMisses[item.id] = missCount
            placed.append(tokens)
            stalestFirst.append(merged.count)
            merged.append(item)
        }

        // 2. Titles no slot claimed are genuinely new media.
        let arrivals = fresh.indices.filter { !claimed[$0] }.map { fresh[$0] }
        var admitted: [String] = []
        var pending = arrivals[...]

        // 3a. Spare capacity first — nothing has to leave for these.
        while let arrival = pending.first, merged.count < limit {
            merged.append(arrival)
            admitted.append(arrival.id)
            pending = pending.dropFirst()
        }

        // 3b. Then over retained-only slots, oldest first, so new media surfaces
        //     soon rather than after everything the viewer has already seen.
        //     Slots the cap is about to truncate are skipped: writing an arrival
        //     into one would report it admitted and then silently drop it.
        for slot in stalestFirst where !pending.isEmpty {
            guard slot < limit else { continue }
            guard !effectivePinned.contains(merged[slot].id) else { continue }
            guard let arrival = pending.first else { break }
            retired.append(merged[slot].id)
            nextMisses[merged[slot].id] = nil
            merged[slot] = arrival
            admitted.append(arrival.id)
            pending = pending.dropFirst()
        }

        // 4. A lowered `maxItems` is the only way to still be over the cap here.
        if merged.count > limit {
            for dropped in merged.dropFirst(limit) {
                retired.append(dropped.id)
                nextMisses[dropped.id] = nil
            }
            merged = Array(merged.prefix(limit))
        }
        return Outcome(
            items: merged,
            admitted: admitted,
            retired: retired,
            misses: nextMisses
        )
    }

    /// The retained slot's new value: the fresh copy, filled out with anything it
    /// lacks that the on-screen copy already had.
    ///
    /// The fresh copy wins outright — including when its id differs, which is how
    /// a show's slide follows Continue Watching from one episode to the next, and
    /// how a cross-server merge moves a title onto a server that can actually
    /// serve it. Keeping the old id there would leave the hero offering a finished
    /// episode or a dead source.
    ///
    /// The exception is a slide the viewer is currently looking at. Swapping which
    /// record it is re-seats the carousel and wipes the backdrop under them, and
    /// on iOS it can strand a committed swipe on an id that no longer exists. Such
    /// a slide keeps its record until they page away, which is the next curation's
    /// problem, not this one's.
    ///
    /// Only the *presentation* the on-screen slide already resolved is carried
    /// over: re-resolving artwork would blank a backdrop that is currently
    /// rendering.
    private static func refreshed(
        _ showing: MediaItem,
        from fresh: MediaItem,
        isPinned: Bool
    ) -> MediaItem {
        guard fresh.id == showing.id || !isPinned else {
            var kept = showing
            kept.fillingMissingPresentation(from: fresh)
            return kept
        }
        var upgraded = fresh
        upgraded.fillingMissingPresentation(from: showing)
        return upgraded
    }
}
