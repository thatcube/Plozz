import Foundation

/// Pure, UI-independent ordering helpers for moving between episodes — used both
/// for auto-advancing when one finishes and for jumping forward/back mid-playback.
/// Kept free of any provider/SwiftUI dependency so it compiles and unit-tests on
/// every platform.
public enum EpisodeSequence {
    /// The previous and next episode relative to `current` within `pool`, in true
    /// broadcast order. `pool` may arrive in any order and may mix seasons: it is
    /// sorted by `(seasonNumber, episodeNumber)` with stable id fallbacks so a
    /// season finale rolls into the next season's premiere. Non-episode entries
    /// and the current item's duplicates are ignored. Returns `(nil, nil)` when
    /// `current` isn't found.
    public static func neighbors(
        of current: MediaItem,
        in pool: [MediaItem]
    ) -> (previous: MediaItem?, next: MediaItem?) {
        let ordered = sorted(pool)
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else {
            return (nil, nil)
        }
        let previous = index > 0 ? ordered[index - 1] : nil
        let next = index < ordered.count - 1 ? ordered[index + 1] : nil
        return (previous, next)
    }

    /// `pool` sorted into broadcast order: by season, then episode, then a stable
    /// fallback on id so equal/unknown ordinals stay deterministic. Episodes
    /// missing ordinals sort after numbered ones rather than being dropped.
    public static func sorted(_ pool: [MediaItem]) -> [MediaItem] {
        pool.sorted { lhs, rhs in
            let ls = lhs.seasonNumber ?? Int.max, rs = rhs.seasonNumber ?? Int.max
            if ls != rs { return ls < rs }
            let le = lhs.episodeNumber ?? Int.max, re = rhs.episodeNumber ?? Int.max
            if le != re { return le < re }
            return lhs.id < rhs.id
        }
    }
}
