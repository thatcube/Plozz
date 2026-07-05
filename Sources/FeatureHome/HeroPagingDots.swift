import Foundation

/// Pure windowing logic for the hero's paging indicator, kept separate from the
/// SwiftUI view so it can be unit-tested.
///
/// The hero can rotate through many slides (`HeroSettings.maxItems`, up to 20),
/// but showing that many dots is noisy. Instead the indicator shows at most
/// `maxVisible` dots as a scrolling **window**: while paging through the middle
/// the active dot is *held* at a fixed slot and the window scrolls under it, and
/// each side that still has off-window slides shows `edgeShrink` progressively
/// smaller dots to signal "more this way". Near the ends the window can't scroll
/// further, so those edge dots grow back to full size and the active dot moves
/// into them — i.e. the last `edgeShrink` dots only become full-size (and the
/// active dot only reaches them) once you're on the last `edgeShrink` slides.
enum HeroPagingDots {
    /// How large to draw a windowed dot. `.small` is the outermost edge dot,
    /// `.medium` the next one in, `.full` every interior dot (and the active dot).
    enum Size: Equatable {
        case full
        case medium
        case small
    }

    /// One rendered dot: which slide it represents and how large to draw it.
    struct Dot: Equatable, Identifiable {
        let index: Int
        let size: Size
        var id: Int { index }
    }

    /// The dots to render for `count` slides with `index` fronted.
    ///
    /// - `count <= maxVisible`: every slide, full size (the classic look).
    /// - otherwise: a window of exactly `maxVisible` dots. `windowStart` is chosen
    ///   so the active dot is held at the last full slot before the trailing shrink
    ///   band while scrolling, and clamped at the ends so the trailing/leading dots
    ///   grow back to full when there's nothing more that way.
    static func layout(
        count: Int,
        index: Int,
        maxVisible: Int = 8,
        edgeShrink: Int = 2
    ) -> [Dot] {
        guard count > maxVisible else {
            return (0..<max(count, 0)).map { Dot(index: $0, size: .full) }
        }
        let clampedIndex = min(max(index, 0), count - 1)
        // Held slot for the active dot while the window scrolls: the last full slot
        // before the trailing shrink band.
        let holdSlot = maxVisible - 1 - edgeShrink
        let maxStart = count - maxVisible
        let windowStart = min(max(clampedIndex - holdSlot, 0), maxStart)
        let hasHiddenLeft = windowStart > 0
        let hasHiddenRight = windowStart + maxVisible < count

        return (0..<maxVisible).map { slot in
            var size = Size.full
            if hasHiddenLeft {
                size = smaller(size, sizeForDepth(slot, edgeShrink: edgeShrink))
            }
            if hasHiddenRight {
                size = smaller(size, sizeForDepth(maxVisible - 1 - slot, edgeShrink: edgeShrink))
            }
            return Dot(index: windowStart + slot, size: size)
        }
    }

    /// The dot size at `depth` from a hidden edge (0 = outermost). Everything beyond
    /// the `edgeShrink` band is full size.
    private static func sizeForDepth(_ depth: Int, edgeShrink: Int) -> Size {
        guard depth < edgeShrink else { return .full }
        return depth == 0 ? .small : .medium
    }

    /// Returns the smaller of two sizes (`.small` < `.medium` < `.full`), so a dot
    /// that is an edge dot on *both* sides takes the smaller treatment.
    private static func smaller(_ a: Size, _ b: Size) -> Size {
        func rank(_ s: Size) -> Int {
            switch s {
            case .small: return 0
            case .medium: return 1
            case .full: return 2
            }
        }
        return rank(a) <= rank(b) ? a : b
    }
}
