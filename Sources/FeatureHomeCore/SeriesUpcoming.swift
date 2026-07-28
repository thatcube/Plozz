import Foundation
import CoreModels

/// Turns a series' persisted schedule into the placeholder rail entries and hero
/// line the series page shows.
///
/// Kept as pure functions over already-resolved data so the series page never waits
/// on a network call to decide what to draw — the schedule is read from cache, and a
/// series with no cached record simply shows nothing extra.
public enum SeriesUpcoming {
    /// Placeholder items for the episodes of `season` that haven't aired yet.
    ///
    /// Matched on season number rather than season id: a schedule provider knows
    /// nothing about the ids on the user's server.
    ///
    /// ## Two numbering conventions
    /// Anime is split. Long-running shonen (One Piece, Detective Conan) is numbered
    /// **absolutely** — "episode 1087", not "S23E17" — while seasonal cour anime and
    /// western TV are numbered **per season**. Libraries follow suit: media servers
    /// usually organise by season, but Plex has an explicit absolute mode. Providers
    /// disagree too: AniList reports absolute numbers with no season, TVmaze and
    /// TheTVDB report per-season.
    ///
    /// So neither form is "correct" — what matters is that a placeholder matches the
    /// numbering **the library beside it is using**, or the card reads as unrelated
    /// to the episodes it sits next to. Rather than guess a conversion (which
    /// ``UpcomingEpisode`` explicitly forbids), an entry is accepted when it
    /// *continues the sequence already on screen*: a per-season entry whose season
    /// matches, or an absolute entry that carries on from the highest owned episode
    /// number. A library showing E4 accepts absolute 5 and rejects absolute 1087;
    /// one showing E1086 accepts 1087. Neither case invents a number.
    ///
    /// Entries already owned are filtered out: a server that carries an episode
    /// early (or a schedule that lags a release) must not produce a duplicate card
    /// alongside the real one.
    public static func placeholders(
        for seasonNumber: Int?,
        seriesID: String?,
        seriesTitle: String?,
        ownedEpisodes: [MediaItem],
        schedule: [UpcomingEpisode],
        seriesArtwork: MediaItem? = nil
    ) -> [MediaItem] {
        guard let seasonNumber else { return [] }
        let ownedNumbers = Set(ownedEpisodes.compactMap(\.episodeNumber))
        let highestOwned = ownedNumbers.max()
        return schedule
            .compactMap { episode -> (UpcomingEpisode, Int)? in
                guard let number = placedNumber(
                    for: episode,
                    seasonNumber: seasonNumber,
                    highestOwned: highestOwned
                ) else { return nil }
                return ownedNumbers.contains(number) ? nil : (episode, number)
            }
            .sorted { $0.0.airDate < $1.0.airDate }
            .map { pair in
                let (episode, number) = pair
                return MediaItem(
                    // Namespaced so it can never collide with a real server id, and
                    // is stable across refreshes so focus survives a reload.
                    id: "upcoming:\(seriesID ?? "series"):s\(seasonNumber)e\(number)",
                    title: episode.title ?? "Episode \(number)",
                    kind: .episode,
                    parentTitle: seriesTitle,
                    seasonNumber: seasonNumber,
                    episodeNumber: number,
                    seriesID: seriesID,
                    // The series' own LANDSCAPE artwork, never an episode still: an
                    // unaired episode rarely has one, and borrowing a neighbouring
                    // episode's would misrepresent it.
                    //
                    // `posterURL` is deliberately left nil. The `.episodeThumbnail`
                    // placement tries it before `backdropURL`, so putting the series'
                    // vertical poster there would crop a portrait image into a 16:9
                    // card.
                    backdropURL: seriesArtwork?.backdropURL ?? seriesArtwork?.heroBackdropURL,
                    fallbackArtworkURL: seriesArtwork?.fallbackArtworkURL,
                    scheduledAirDate: episode.airDate,
                    scheduledAirDateHasTime: episode.datePrecision == .dateAndTime
                )
            }
    }

    /// The episode number this entry should carry in `seasonNumber`'s rail, or `nil`
    /// when it belongs to another season or uses a numbering the library isn't.
    ///
    /// See ``placeholders(for:seriesID:seriesTitle:ownedEpisodes:schedule:seriesArtwork:)``
    /// for why this is matched rather than converted.
    static func placedNumber(
        for episode: UpcomingEpisode,
        seasonNumber: Int,
        highestOwned: Int?
    ) -> Int? {
        // Per-season: the provider states a season, so it either matches or doesn't.
        if let providerSeason = episode.seasonNumber {
            guard providerSeason == seasonNumber, let number = episode.episodeNumber else { return nil }
            return number
        }
        // Absolute (AniList): usable only where it continues what the library shows,
        // which is exactly when the library is absolute-ordered too. With nothing
        // owned there is no sequence to continue, so it stays out.
        guard let absolute = episode.absoluteEpisodeNumber, let highestOwned else { return nil }
        return absolute > highestOwned && absolute <= highestOwned + Self.maximumSequenceGap
            ? absolute
            : nil
    }

    /// How far past the highest owned episode an absolute number may sit and still
    /// count as continuing the sequence. Covers a viewer a few episodes behind
    /// without letting a wholly different numbering (E4 vs 1087) slip through.
    static let maximumSequenceGap = 26

    /// The hero's air-schedule line, e.g. "New episodes Fridays" or
    /// "New episode Aug 5" — or `nil` when there is nothing truthful to say.
    ///
    /// A cadence is only phrased as a repeating weekday when the provider states a
    /// single airing day (see ``AirCadence``); anything else names the next date,
    /// which is always accurate even for an irregular or batch release.
    public static func heroLine(
        nextEpisode: UpcomingEpisode?,
        cadence: AirCadence?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let nextEpisode else { return nil }
        let isSeasonPremiere = nextEpisode.episodeNumber == 1

        if let cadence, cadence.isSingleWeekday, let weekday = cadence.weekdays.first,
           !isSeasonPremiere, !isWithinAWeek(nextEpisode.airDate, from: now, calendar: calendar) {
            // A repeating cadence is the more useful phrasing, but only once the
            // next episode is far enough out that naming the day isn't vaguer than
            // naming the date — and never for a premiere, where the date is the news.
            return "New episodes \(pluralWeekday(weekday))"
        }

        let label = isSeasonPremiere ? "New season" : "New episode"
        if let relative = relativeDay(nextEpisode.airDate, from: now, calendar: calendar) {
            return "\(label) \(relative)"
        }
        return "\(label) \(formattedDate(nextEpisode.airDate, calendar: calendar))"
    }

    /// "today" / "tomorrow" / a weekday name inside the coming week, else `nil` so
    /// the caller falls back to an explicit date.
    static func relativeDay(_ date: Date, from now: Date, calendar: Calendar) -> String? {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<0: return nil
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6:
            // Same reason as `pluralWeekday`: a locale-less `Calendar` would give
            // the abbreviated name here.
            let weekday = calendar.component(.weekday, from: date)
            guard let symbols = weekdayNameFormatter.weekdaySymbols, symbols.count == 7 else { return nil }
            return symbols[weekday - 1]
        default: return nil
        }
    }

    private static func isWithinAWeek(_ date: Date, from now: Date, calendar: Calendar) -> Bool {
        relativeDay(date, from: now, calendar: calendar) != nil
    }

    /// The plural form used for a repeating day ("Fridays").
    ///
    /// The weekday name comes from a `DateFormatter`, not `Calendar.weekdaySymbols`:
    /// a `Calendar` built by identifier carries no locale, so its symbols are the
    /// *abbreviated* ones and this produced "Fris". Pluralising by appending "s" is
    /// English-shaped and is the fallback until the string is localized properly.
    private static func pluralWeekday(_ weekday: Int) -> String {
        let symbols = weekdayNameFormatter.weekdaySymbols ?? []
        guard symbols.count == 7 else { return "" }
        let symbol = symbols[max(0, min(6, weekday - 1))]
        return symbol.hasSuffix("s") ? symbol : symbol + "s"
    }

    /// Supplies full, locale-aware weekday names.
    private static let weekdayNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        return f
    }()

    /// A short "Aug 5" style date, with the year only when it isn't the current one.
    static func formattedDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(
            sameYear
                ? .dateTime.month(.abbreviated).day()
                : .dateTime.month(.abbreviated).day().year()
        )
    }

    /// The air-date caption a placeholder card shows in place of duration/progress.
    public static func cardCaption(
        for item: MediaItem,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let date = item.scheduledAirDate else { return nil }
        if let relative = relativeDay(date, from: now, calendar: calendar) {
            return relative.capitalized
        }
        return formattedDate(date, now: now, calendar: calendar)
    }
}
