import Foundation

/// User-configurable spoiler protection for unwatched / future episodes
/// (pure data model, mirrors `CaptionSettings`).
///
/// When enabled, episode artwork and text are hidden so a series can be browsed
/// without leaking what happens next. The decision of *what* to hide for a given
/// item lives in the pure functions below so it can be unit-tested without any
/// UI, and so SwiftUI views can be handed a plain value for cheap diffing.
public struct SpoilerSettings: Codable, Equatable, Sendable {
    /// How a hidden episode thumbnail is presented.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Show the real artwork, blurred.
        case blur
        /// Never load the real episode image; show generic series fan-art with
        /// the episode number instead, so not even a blurred frame can leak.
        case placeholder

        public var displayName: String {
            switch self {
            case .blur: return "Blur Thumbnail"
            case .placeholder: return "Placeholder Art"
            }
        }
    }

    /// Master switch. Off by default — opt-in only.
    public var isEnabled: Bool
    /// How hidden thumbnails are presented.
    public var mode: Mode

    public init(
        isEnabled: Bool = false,
        mode: Mode = .blur
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
    }

    public static let `default` = SpoilerSettings()
}

// MARK: - Decision logic (pure, unit-tested)

public extension SpoilerSettings {
    /// Whether `item` is partially watched but not finished — the user is
    /// actively in the middle of it.
    private static func isInProgress(_ item: MediaItem) -> Bool {
        guard !item.isPlayed else { return false }
        if let percentage = item.playedPercentage, percentage > 0.01 { return true }
        if let resume = item.resumePosition, resume > 0 { return true }
        return false
    }

    /// Only episodes are ever treated as spoilers; movies, series and seasons
    /// are always shown.
    private static func isSpoilerCandidate(_ item: MediaItem) -> Bool {
        item.kind == .episode && !item.isPlayed
    }

    /// Hide the episode *thumbnail* only for truly unwatched / future episodes.
    /// In-progress episodes keep their thumbnail (the user already knows where
    /// they are), and fully-played episodes are never hidden.
    func shouldHideThumbnail(for item: MediaItem) -> Bool {
        guard isEnabled else { return false }
        guard Self.isSpoilerCandidate(item) else { return false }
        return !Self.isInProgress(item)
    }

    /// Hide the episode *title and overview* for any episode that has not been
    /// fully watched — including in-progress ones — since the description can
    /// spoil the rest of an episode the viewer hasn't finished.
    func shouldHideText(for item: MediaItem) -> Bool {
        guard isEnabled else { return false }
        return Self.isSpoilerCandidate(item)
    }

    /// A spoiler-safe display title for a hidden episode, e.g. `Episode 5`.
    func maskedTitle(for item: MediaItem) -> String {
        if let number = item.episodeNumber { return "Episode \(number)" }
        return "Episode"
    }
}
