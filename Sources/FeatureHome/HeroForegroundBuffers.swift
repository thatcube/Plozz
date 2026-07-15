import Foundation

/// Pure ring-buffer index math for the experimental double-buffered hero
/// foreground (`PLZHERO_BUFFERED_FOREGROUND`). Maps a bounded set of visual
/// **slots** (default 3: previous / current / next) to item indices so the
/// adjacent slides' *visual* foreground can be pre-built and pre-laid-out during
/// the dwell and then swapped in at page time *without rebuilding the foreground
/// on the transition frame*.
///
/// The invariant that makes buffering cheap: because the hero only ever pages by
/// ±1 (with wraparound — see `HomeHeroView.page(to:)`), the destination slide is
/// **already prepared** in an adjacent slot before every page. Paging therefore
/// just rotates which slot is "current" (a single `Int`); the destination slot's
/// *content is unchanged that frame*, and only the one slot that rotated off the
/// far edge needs re-seeding — which the view does **offscreen, after the wipe**
/// via ``refreshNeighbors(itemCount:)``, so the reseed's SwiftUI diff never lands
/// on the paging frame.
///
/// SwiftUI-free and exhaustively unit-testable (that is the whole point of
/// isolating it here).
struct HeroForegroundBuffers: Equatable, Sendable {
    /// Bounded window size. Three slots — previous, current, next — is the minimum
    /// that lets a ±1 page always land on an already-prepared buffer while keeping
    /// memory/layout cost to two extra foreground trees regardless of how many
    /// titles the carousel rotates through.
    static let slotCount = 3

    /// The physical slot currently fronted. Rotating this (not rebuilding
    /// assignments) is what makes a page cheap.
    private(set) var currentSlot: Int

    /// `assignments[slot]` = the item index that physical slot displays, or `nil`
    /// when the carousel is too small to fill every slot (e.g. a 1- or 2-item
    /// carousel). Indexed by physical slot, which is stable — the SwiftUI identity
    /// the buffered views key on — while `currentSlot` rotates through it.
    private(set) var assignments: [Int?]

    /// Seeds a fresh window centered on `index` (previous / current / next).
    init(itemCount: Int, index: Int) {
        currentSlot = 0
        assignments = Array(repeating: nil, count: Self.slotCount)
        reseedAll(itemCount: itemCount, index: index)
    }

    /// The item index displayed by a physical `slot`, if the slot maps to one.
    func itemIndex(forSlot slot: Int) -> Int? {
        guard assignments.indices.contains(slot) else { return nil }
        return assignments[slot]
    }

    /// The physical slot currently displaying `index`, or `nil` if that item isn't
    /// prepared in any slot.
    func slot(forItemIndex index: Int) -> Int? {
        assignments.firstIndex { $0 == index }
    }

    /// The item index of the fronted slot.
    var currentItemIndex: Int? { itemIndex(forSlot: currentSlot) }

    /// Physical slot that holds the *next* (forward) neighbour.
    var nextSlot: Int { (currentSlot + 1) % Self.slotCount }

    /// Physical slot that holds the *previous* (backward) neighbour.
    var previousSlot: Int { (currentSlot + Self.slotCount - 1) % Self.slotCount }

    /// Rebuilds every slot around `index`: current -> `index`, next -> `index+1`,
    /// previous -> `index-1` (both wrapping). Used on first appearance and whenever
    /// the fronted slide is re-seated by a **non-adjacent** change (curated set
    /// swap, clamp, or a page that isn't ±1 from the prepared current) where no
    /// prepared buffer can be reused. This *can* rebuild visible content, so
    /// callers keep it off the hot ±1 paging path.
    mutating func reseedAll(itemCount: Int, index: Int) {
        guard itemCount > 0 else {
            assignments = Array(repeating: nil, count: Self.slotCount)
            currentSlot = 0
            return
        }
        let clamped = min(max(index, 0), itemCount - 1)
        currentSlot = 0
        assignments[currentSlot] = clamped
        assignments[nextSlot] = Self.neighbour(of: clamped, offset: 1, itemCount: itemCount)
        assignments[previousSlot] = Self.neighbour(of: clamped, offset: -1, itemCount: itemCount)
    }

    /// Advances the window to `newIndex` **only if** it is an adjacent (±1,
    /// wrapping) page whose destination is already prepared in a neighbouring slot
    /// — the only kind the hero performs in normal use.
    ///
    /// On success it rotates `currentSlot` so the destination's already-built
    /// buffer becomes current **without changing any slot's content this frame**,
    /// and returns `true`. The single slot that rotated off the far edge still
    /// holds its stale (offscreen) content until the caller calls
    /// ``refreshNeighbors(itemCount:)`` off the transition frame.
    ///
    /// Returns `false` — mutating nothing — when `newIndex` is not an adjacent
    /// prepared page; the caller should ``reseedAll(itemCount:index:)`` instead,
    /// accepting the one-off rebuild (a rare set-swap / clamp, never a hot page).
    mutating func page(toIndex newIndex: Int, itemCount: Int) -> Bool {
        guard itemCount > 0,
              let currentIndex = currentItemIndex,
              newIndex >= 0, newIndex < itemCount,
              newIndex != currentIndex
        else { return false }

        let forwardIndex = Self.neighbour(of: currentIndex, offset: 1, itemCount: itemCount)
        let backwardIndex = Self.neighbour(of: currentIndex, offset: -1, itemCount: itemCount)

        if newIndex == forwardIndex, assignments[nextSlot] == newIndex {
            currentSlot = nextSlot
            return true
        }
        if newIndex == backwardIndex, assignments[previousSlot] == newIndex {
            currentSlot = previousSlot
            return true
        }
        return false
    }

    /// Re-seeds the two non-current slots to the correct previous/next neighbours
    /// of the fronted slide. Idempotent and self-correcting: it reads the live
    /// `currentSlot` / `currentItemIndex`, so a late call after a newer page still
    /// leaves the window correct for the current state. Called by the view **after
    /// the wipe** so the one far slot whose content changed diffs offscreen, never
    /// on the transition frame.
    mutating func refreshNeighbors(itemCount: Int) {
        guard itemCount > 0, let currentIndex = currentItemIndex else { return }
        assignments[nextSlot] = Self.neighbour(of: currentIndex, offset: 1, itemCount: itemCount)
        assignments[previousSlot] = Self.neighbour(of: currentIndex, offset: -1, itemCount: itemCount)
    }

    /// A neighbour item index, wrapping. Returns `nil` only for an empty carousel;
    /// a 1-item carousel wraps to itself (so every slot maps to index 0).
    private static func neighbour(of index: Int, offset: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        return ((index + offset) % itemCount + itemCount) % itemCount
    }
}
