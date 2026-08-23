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

        public var displayName: LocalizedStringResource {
            switch self {
            case .blur:
                return LocalizedStringResource(
                    "spoilerMode.blur",
                    defaultValue: "Blur Thumbnail",
                    comment: "Spoiler-protection style option in Settings."
                )
            case .placeholder:
                return LocalizedStringResource(
                    "spoilerMode.placeholder",
                    defaultValue: "Placeholder Art",
                    comment: "Spoiler-protection style option in Settings."
                )
            }
        }
    }

    /// Master switch. Off by default — opt-in only.
    public var isEnabled: Bool
    /// How hidden thumbnails are presented.
    public var mode: Mode
    /// When enabled, external ratings (IMDb, Rotten Tomatoes, …) are hidden until
    /// a title has been fully watched, so the score can't bias the viewer
    /// beforehand — on shows and seasons as well as movies and episodes, since
    /// "how good is this" is exactly the question a series page is consulted for.
    /// Independent of `isEnabled` — it's its own opt-in switch. Off by default.
    public var hideRatingsUntilWatched: Bool

    public init(
        isEnabled: Bool = false,
        mode: Mode = .blur,
        hideRatingsUntilWatched: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.hideRatingsUntilWatched = hideRatingsUntilWatched
    }

    public static let `default` = SpoilerSettings()
}

// MARK: - Codable (tolerant of older persisted payloads)

public extension SpoilerSettings {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, mode, hideRatingsUntilWatched
    }

    /// Decodes leniently so settings saved before a field existed still load
    /// instead of resetting the whole struct to its defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SpoilerSettings.default
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        self.mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? defaults.mode
        self.hideRatingsUntilWatched = try container.decodeIfPresent(Bool.self, forKey: .hideRatingsUntilWatched) ?? defaults.hideRatingsUntilWatched
    }
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

    /// A spoiler-safe display resource for a hidden episode, e.g. `Episode 5`.
    /// Genuinely our own copy — not provider content. Returns a
    /// `LocalizedStringResource` rather than a `String`/`Text`: `CoreModels`
    /// can't import SwiftUI, so the caller (which can) composes the final
    /// `Text(maskedTitle(for: item))`, choosing it in place of the real
    /// (content) title whenever it has separately decided to hide the item's
    /// text (`shouldHideText`). `"Episode \(number)"` is a count-bearing phrase
    /// that needs a plural catalog variant.
    func maskedTitle(for item: MediaItem) -> LocalizedStringResource {
        if let number = item.episodeNumber {
            return LocalizedStringResource(
                "Episode \(number)",
                comment: "Placeholder title shown instead of the real title for a spoiler-protected (unwatched) episode, giving only its episode number."
            )
        }
        return LocalizedStringResource(
            "Episode",
            comment: "Placeholder title shown instead of the real title for a spoiler-protected (unwatched) episode whose episode number isn't known."
        )
    }

    /// Hide external ratings until the title has been fully watched, so the score
    /// doesn't bias the viewer before they see it.
    ///
    /// Applies to containers as much as to the things inside them: a series page
    /// *is* the page you look at before deciding to start a show, and "how good is
    /// this" is precisely what the setting is asked to withhold. So a series or
    /// season is covered until it is finished, exactly like the movie or episode
    /// it stands in for. In-progress items stay hidden too — the score is revealed
    /// on finishing, not on starting.
    ///
    /// Kinds with no meaningful watched state (collections, folders) are never
    /// hidden: there is nothing to finish, so they would be hidden forever.
    func shouldHideRatings(for item: MediaItem) -> Bool {
        guard hideRatingsUntilWatched else { return false }
        switch item.kind {
        case .movie, .episode, .series, .season, .video:
            return !item.isPlayed
        default:
            return false
        }
    }
}
