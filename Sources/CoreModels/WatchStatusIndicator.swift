import Foundation

/// Which watch-status indicator media cards paint in the artwork corner (pure
/// data model).
///
/// A per-profile display preference that sits alongside `CardStyle`: it doesn't
/// change how cards look, only *which* end of the watch spectrum gets a corner
/// mark.
/// - `.watched` marks what you've **finished** — the classic check badge.
/// - `.unwatched` marks what you **haven't started** — a solid blue corner flag,
///   the way Infuse does it (and the way Plex used to).
///
/// Persisted **per profile** like `CardStyle` / `UIDensity`; the concrete
/// rendering lives in `CoreUI` (`PosterCardView`), so this stays Foundation-only
/// and the Settings screen can edit it without importing SwiftUI.
public enum WatchStatusIndicator: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Mark finished items with a check badge in the corner (the default, and the
    /// app's long-standing behaviour).
    case watched
    /// Mark not-yet-started items with a solid corner flag instead, leaving
    /// finished items unmarked. In-progress items always show their progress bar
    /// regardless of this choice.
    case unwatched

    public var id: String { rawValue }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: String {
        switch self {
        case .watched: return "Watched"
        case .unwatched: return "Unwatched"
        }
    }

    /// Tiny line shown beneath the picker, updated live as focus moves.
    public var detail: String {
        switch self {
        case .watched: return "Check badge on watched items."
        case .unwatched: return "Corner flag on unwatched items."
        }
    }

    public static let `default`: WatchStatusIndicator = .unwatched
}
