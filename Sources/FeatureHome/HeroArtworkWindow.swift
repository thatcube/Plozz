import Foundation

/// A fixed-size, wraparound neighborhood used for hero artwork warming. Its size
/// is independent of the user's hero item count, preventing a 20-item carousel
/// from turning into a 20-image speculative decode.
enum HeroArtworkWindow {
    private static let offsets = [0, 1, -1, 2, -2]

    static func indices(count: Int, centeredAt index: Int) -> [Int] {
        guard count > 0 else { return [] }
        let center = min(max(index, 0), count - 1)
        var seen = Set<Int>()
        return offsets.compactMap { offset in
            let candidate = (center + offset + count) % count
            return seen.insert(candidate).inserted ? candidate : nil
        }
    }
}

/// Full-carousel order for lightweight preview warming. Alternating forward and
/// backward distance makes either first paging direction cache-hot, while keeping
/// the current/adjacent slides ahead of distant work.
enum HeroPreviewWarmOrder {
    static func indices(count: Int, centeredAt index: Int) -> [Int] {
        guard count > 0 else { return [] }
        let center = min(max(index, 0), count - 1)
        var result = [center]
        var seen: Set<Int> = [center]
        var distance = 1
        while result.count < count {
            for offset in [distance, -distance] {
                let candidate = (center + offset + count) % count
                if seen.insert(candidate).inserted {
                    result.append(candidate)
                    if result.count == count { return result }
                }
            }
            distance += 1
        }
        return result
    }
}
