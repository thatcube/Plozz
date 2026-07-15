import Foundation

/// The bounded, wraparound neighbourhood the experimental hero foreground
/// **rasterizer** prepares ahead of a transition (gated by
/// `PLZHERO_RASTER_FOREGROUND`). Its size is a fixed radius around the fronted
/// slide — independent of how many titles the carousel rotates through — so a
/// 20-slide hero never turns into 20 speculative snapshot renders.
///
/// The order is deliberately *paging-priority*: the fronted slide first, then the
/// immediate next/previous, then the ±2 ring. That makes the very next manual
/// press — forward **or** backward, the maintainer's #1 priority over
/// auto-advance — the most likely to be already prepared, and lets a bounded
/// prepare pass stop early under memory pressure while still covering both
/// directions and a mid-transition reversal.
///
/// Pure value logic (no SwiftUI/UIKit) so it is fully unit-testable off-device.
enum HeroRasterWindow {
    /// Default radius: current ±2 → a 5-slot window (unless the carousel is
    /// smaller, in which case it collapses to the distinct slides available).
    static let defaultRadius = 2

    /// The item indices to keep prepared for a `count`-slide carousel with `index`
    /// fronted, in paging priority and de-duplicated. Wraps around the ends so the
    /// window is symmetric even on the first/last slide (paging wraps too).
    ///
    /// - `count <= 0` → empty.
    /// - `count == 1` → `[0]`.
    /// - `count == 2` → `[0, 1]` (or `[1, 0]`), the two distinct slides once.
    /// - otherwise → `[center, +1, -1, +2, -2]` mapped into range, deduped.
    static func indices(count: Int, centeredAt index: Int, radius: Int = defaultRadius) -> [Int] {
        guard count > 0 else { return [] }
        let clampedRadius = max(0, radius)
        let center = min(max(index, 0), count - 1)

        // Build the offset order: 0, +1, -1, +2, -2, … out to ±radius. This keeps
        // the immediate neighbours (either paging direction) ahead of the outer ring.
        var offsets = [0]
        for step in 1...max(1, clampedRadius) where step <= clampedRadius {
            offsets.append(step)
            offsets.append(-step)
        }

        var seen = Set<Int>()
        return offsets.compactMap { offset in
            let candidate = ((center + offset) % count + count) % count
            return seen.insert(candidate).inserted ? candidate : nil
        }
    }
}
