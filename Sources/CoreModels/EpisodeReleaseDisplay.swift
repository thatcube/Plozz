import Foundation

/// A presentation-ready rendering of an ``EpisodeReleaseState`` — the strings a view
/// shows for a series' "Next episode" line and per-episode badges. Pure (no SwiftUI)
/// so the wording, spoiler handling, and locale/timezone formatting are all unit
/// tested in one place.
///
/// Rules honored:
/// - **Spoilers:** when enabled, the upcoming episode *title* is hidden but its
///   season/episode (or absolute) number and air date are kept.
/// - **Precision:** an exact timestamp is localized to the device locale/timezone
///   (date + time); a date-only schedule shows just the date with **no invented time**.
/// - **Expected, not guaranteed:** schedule-derived states are flagged so the UI can
///   mark them as an estimate rather than a promise.
public struct EpisodeReleaseDisplay: Equatable, Sendable {
    /// A short badge, or `nil` for a present episode (ordinary content, no badge).
    public var badge: String?
    /// The numbering label, e.g. `"S1 E2"` or `"Ep 1075"`; `nil` when unknown.
    public var numberLabel: String?
    /// The formatted air date (date, or date + time for exact schedules); `nil` for a
    /// present episode.
    public var dateLabel: String?
    /// The episode title to show, already spoiler-filtered (`nil` when hidden/absent).
    public var title: String?
    /// Whether this reading is a schedule estimate the UI should mark as
    /// "expected, not guaranteed".
    public var isExpectedNotGuaranteed: Bool

    public init(
        badge: String? = nil,
        numberLabel: String? = nil,
        dateLabel: String? = nil,
        title: String? = nil,
        isExpectedNotGuaranteed: Bool = false
    ) {
        self.badge = badge
        self.numberLabel = numberLabel
        self.dateLabel = dateLabel
        self.title = title
        self.isExpectedNotGuaranteed = isExpectedNotGuaranteed
    }

    /// A one-line "Next episode" summary joining the parts that are present, e.g.
    /// `"Airing soon · S1 E2 · May 1, 2030"`. Excludes the (separately shown) title.
    public var summaryLine: String {
        [badge, numberLabel, dateLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// Builds the display for a release `state`.
    public static func make(
        for state: EpisodeReleaseState,
        spoilersEnabled: Bool,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> EpisodeReleaseDisplay {
        guard let upcoming = state.upcomingEpisode else {
            // Present: ordinary content, no schedule badge.
            return EpisodeReleaseDisplay()
        }
        let number = numberLabel(for: upcoming)
        let date = dateLabel(for: upcoming, locale: locale, timeZone: timeZone)
        let title = spoilersEnabled ? nil : upcoming.title?.nonBlank

        switch state {
        case .upcoming:
            return EpisodeReleaseDisplay(
                badge: "Airing soon", numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .airedGracePeriod:
            return EpisodeReleaseDisplay(
                badge: "Aired today", numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .airedMissing:
            return EpisodeReleaseDisplay(
                badge: "Not in your library", numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .requested:
            return EpisodeReleaseDisplay(
                badge: "Requested", numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: false)
        case .present:
            return EpisodeReleaseDisplay()
        }
    }

    /// `"S1 E2"` for a per-season schedule, `"Ep 1075"` for an absolute one, else `nil`.
    static func numberLabel(for upcoming: UpcomingEpisode) -> String? {
        if let season = upcoming.seasonNumber, let episode = upcoming.episodeNumber {
            return "S\(season) E\(episode)"
        }
        if let absolute = upcoming.absoluteEpisodeNumber {
            return "Ep \(absolute)"
        }
        return nil
    }

    static func dateLabel(for upcoming: UpcomingEpisode, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch upcoming.datePrecision {
        case .dateAndTime:
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        case .dateOnly:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: upcoming.airDate)
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
