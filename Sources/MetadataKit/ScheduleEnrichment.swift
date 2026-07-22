import Foundation
import CoreModels

/// A provider-neutral "next known episode" before it is tied to a series identity.
///
/// Each schedule provider (TVmaze / AniList / TheTVDB) decodes its own payload into
/// this shape, then stamps it with the series identity + source it resolved. Keeping
/// the mapping in one tested place means numbering rules (per-season vs absolute) and
/// date precision are decided identically everywhere.
public struct ProviderNextEpisode: Sendable, Equatable, Hashable {
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var absoluteEpisodeNumber: Int?
    public var title: String?
    public var airDate: Date
    public var datePrecision: AirDatePrecision
    public var sourceURL: URL?

    public init(
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        absoluteEpisodeNumber: Int? = nil,
        title: String? = nil,
        airDate: Date,
        datePrecision: AirDatePrecision,
        sourceURL: URL? = nil
    ) {
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.absoluteEpisodeNumber = absoluteEpisodeNumber
        self.title = title
        self.airDate = airDate
        self.datePrecision = datePrecision
        self.sourceURL = sourceURL
    }

    /// Ties this raw schedule to the resolving series identity + provider, producing
    /// the persisted/domain ``UpcomingEpisode``.
    public func upcomingEpisode(
        seriesIdentity: MediaIdentity,
        source: MetadataSource,
        refreshedAt: Date
    ) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: seriesIdentity,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            absoluteEpisodeNumber: absoluteEpisodeNumber,
            title: title,
            airDate: airDate,
            datePrecision: datePrecision,
            source: source,
            sourceURL: sourceURL,
            refreshedAt: refreshedAt
        )
    }
}

/// Parses TheTVDB / TVmaze style `yyyy-MM-dd` calendar days (no time) into a `Date`
/// at the start of that day in the device time zone. Used for `dateOnly` schedules.
enum ScheduleDateParsing {
    static let calendarDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// ISO-8601 with a time component (e.g. TVmaze `airstamp`).
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func calendarDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return calendarDay.date(from: raw)
    }

    static func instant(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return iso8601.date(from: raw) ?? iso8601WithFractional.date(from: raw)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
