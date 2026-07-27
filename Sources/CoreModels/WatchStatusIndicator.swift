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
    public var displayName: LocalizedStringResource {
        switch self {
        case .watched:
            return LocalizedStringResource(
                "watchIndicator.watched",
                defaultValue: "Watched",
                comment: "Watch-status badge style option in Settings > Appearance."
            )
        case .unwatched:
            return LocalizedStringResource(
                "watchIndicator.unwatched",
                defaultValue: "Unwatched",
                comment: "Watch-status badge style option in Settings > Appearance."
            )
        }
    }

    /// Tiny line shown beneath the picker, updated live as focus moves.
    public var detail: LocalizedStringResource {
        switch self {
        case .watched:
            return LocalizedStringResource(
                "watchIndicator.detail.watched",
                defaultValue: "Check badge on watched items.",
                comment: "One-line explanation shown under the watch-indicator picker."
            )
        case .unwatched:
            return LocalizedStringResource(
                "watchIndicator.detail.unwatched",
                defaultValue: "Corner flag on unwatched items.",
                comment: "One-line explanation shown under the watch-indicator picker."
            )
        }
    }

    public static let `default`: WatchStatusIndicator = .unwatched
}
