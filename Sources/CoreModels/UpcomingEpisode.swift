import Foundation

/// How precisely a scheduled air date is known.
///
/// Providers differ: AniList's `nextAiringEpisode.airingAt` is an exact Unix
/// timestamp (`dateAndTime`); TheTVDB's `nextAired` is a bare calendar day with no
/// time (`dateOnly`). The distinction drives both display (never invent a time for a
/// date-only schedule) and the grace-period rule (an exact timestamp waits a short
/// grace after air time before a missing episode is flagged; a date-only schedule
/// waits until the following local day).
public enum AirDatePrecision: String, Codable, Sendable, Hashable {
    /// A calendar day only — no meaningful time-of-day.
    case dateOnly
    /// A precise instant (date and time), safe to localize to the device clock.
    case dateAndTime
}

/// A single known-upcoming (or just-aired) episode for a series, as reported by a
/// free schedule provider (AniList / TVmaze / TheTVDB).
///
/// This is deliberately *schedule-only*: it says "the next known episode of this
/// series is expected at `airDate`", carrying whichever numbering the provider gave.
/// Whether that episode is actually owned across the user's sources is decided
/// elsewhere (the release-state machine), never assumed here.
///
/// ## Numbering (do not guess a conversion)
/// `seasonNumber`/`episodeNumber` and `absoluteEpisodeNumber` are kept **separate**.
/// Western TV providers report per-season `(S, E)`; anime providers (AniList) report
/// an **absolute** episode counter. When a provider gives only one form, the other
/// stays `nil` — the comparison layer must never fabricate a season/episode from an
/// absolute number (or vice-versa) when providers disagree.
public struct UpcomingEpisode: Codable, Sendable, Equatable, Hashable {
    /// The identity of the series this schedule belongs to (the strong external id
    /// the resolving provider keyed on, e.g. `.external("anilist", "1")`).
    public var seriesIdentity: MediaIdentity
    /// Per-season season number, when the provider numbers per season. `nil` for
    /// absolute-numbered anime.
    public var seasonNumber: Int?
    /// Per-season episode number, when the provider numbers per season. `nil` for
    /// absolute-numbered anime.
    public var episodeNumber: Int?
    /// Absolute episode counter, when the provider numbers absolutely (anime).
    /// Kept separate from `(seasonNumber, episodeNumber)` and never converted.
    public var absoluteEpisodeNumber: Int?
    /// The episode title, when known. Hidden by the spoiler settings in the UI.
    public var title: String?
    /// When the episode is expected to air. Interpret with `datePrecision`.
    public var airDate: Date
    /// Whether `airDate` carries a meaningful time-of-day.
    public var datePrecision: AirDatePrecision
    /// Which provider supplied this schedule.
    public var source: MetadataSource
    /// A stable page/API URL for attribution, when available.
    public var sourceURL: URL?
    /// When this schedule was last refreshed from its provider.
    public var refreshedAt: Date

    public init(
        seriesIdentity: MediaIdentity,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        absoluteEpisodeNumber: Int? = nil,
        title: String? = nil,
        airDate: Date,
        datePrecision: AirDatePrecision,
        source: MetadataSource,
        sourceURL: URL? = nil,
        refreshedAt: Date
    ) {
        self.seriesIdentity = seriesIdentity
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.absoluteEpisodeNumber = absoluteEpisodeNumber
        self.title = title
        self.airDate = airDate
        self.datePrecision = datePrecision
        self.source = source
        self.sourceURL = sourceURL
        self.refreshedAt = refreshedAt
    }
}
