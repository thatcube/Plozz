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
    /// A short status badge ("Airing soon", "Requested", ...), or `nil` for a
    /// present episode (ordinary content, no badge). Pure copy — always our own
    /// wording, never server content.
    public var badge: LocalizedStringResource?
    /// The numbering label, e.g. `"S1 E2"` or `"Ep 1075"`; `nil` when unknown.
    public var numberLabel: String?  // l10n:content — formatted numbering scheme, not prose copy
    /// The formatted air date (date, or date + time for exact schedules); `nil` for a
    /// present episode.
    public var dateLabel: String?  // l10n:content — DateFormatter output, already locale-aware
    /// The episode title to show, already spoiler-filtered (`nil` when hidden/absent).
    public var title: String?  // l10n:content — server-provided episode title
    /// Whether this reading is a schedule estimate the UI should mark as
    /// "expected, not guaranteed".
    public var isExpectedNotGuaranteed: Bool

    public init(
        badge: LocalizedStringResource? = nil,
        numberLabel: String? = nil,
        dateLabel: String? = nil,
        title: String? = nil,  // l10n:content — server-provided episode title
        isExpectedNotGuaranteed: Bool = false
    ) {
        self.badge = badge
        self.numberLabel = numberLabel
        self.dateLabel = dateLabel
        self.title = title
        self.isExpectedNotGuaranteed = isExpectedNotGuaranteed
    }

    /// The parts of the "Next episode" summary line, in display order, excluding
    /// the (separately shown) title. Kept as separate values — one localized
    /// resource plus two already-formatted content strings — rather than a
    /// pre-joined `String`, since joining a `LocalizedStringResource` with
    /// content via string interpolation would produce a catalog key with no
    /// words in it. The view composes them, e.g.
    /// `[Text(badge), Text(verbatim: numberLabel), Text(verbatim: dateLabel)]`
    /// joined with " · ".
    public var summaryLineParts: (badge: LocalizedStringResource?, numberLabel: String?, dateLabel: String?) {
        (badge, numberLabel, dateLabel)
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
                badge: LocalizedStringResource(
                    "episodeRelease.badge.upcoming",
                    defaultValue: "Airing soon",
                    comment: "Badge shown on an episode that is scheduled but hasn't aired yet."
                ),
                numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .airedGracePeriod:
            return EpisodeReleaseDisplay(
                badge: LocalizedStringResource(
                    "episodeRelease.badge.airedGracePeriod",
                    defaultValue: "Aired today",
                    comment: "Badge shown on an episode that aired earlier today but may not be in the library yet."
                ),
                numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .airedMissing:
            return EpisodeReleaseDisplay(
                badge: LocalizedStringResource(
                    "episodeRelease.badge.airedMissing",
                    defaultValue: "Not in your library",
                    comment: "Badge shown on an episode that has aired but has not appeared in the library."
                ),
                numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: true)
        case .requested:
            return EpisodeReleaseDisplay(
                badge: LocalizedStringResource(
                    "episodeRelease.badge.requested",
                    defaultValue: "Requested",
                    comment: "Badge shown on an episode that has been requested via Seerr/Overseerr."
                ),
                numberLabel: number, dateLabel: date,
                title: title, isExpectedNotGuaranteed: false)
        case .present:
            return EpisodeReleaseDisplay()
        }
    }

    /// `"S1 E2"` for a per-season schedule, `"Ep 1075"` for an absolute one, else `nil`.
    static func numberLabel(for upcoming: UpcomingEpisode) -> String? {  // l10n:content — formatted numbering scheme, not prose copy
        if let season = upcoming.seasonNumber, let episode = upcoming.episodeNumber {
            return "S\(season) E\(episode)"
        }
        if let absolute = upcoming.absoluteEpisodeNumber {
            return "Ep \(absolute)"
        }
        return nil
    }

    static func dateLabel(for upcoming: UpcomingEpisode, locale: Locale, timeZone: TimeZone) -> String {  // l10n:content — DateFormatter output, already locale-aware
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
