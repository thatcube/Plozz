import Foundation

/// How often a series releases new episodes, when a provider states it outright.
///
/// Deliberately **never inferred from air dates**. A batch drop (a whole season at
/// once) and a weekly release produce very different spacing, and a run of
/// same-weekday dates can be coincidence — so a cadence is only claimed when the
/// provider says so (TheTVDB's `airsDays`/`airsTime`). Absent that, the UI falls
/// back to naming the next date rather than inventing a pattern.
public struct AirCadence: Codable, Sendable, Equatable, Hashable {
    /// Weekdays the series airs on, in `Calendar` terms (1 = Sunday), week order.
    /// Empty when the provider reports no weekday.
    public var weekdays: [Int]
    /// The usual broadcast time as reported (e.g. `"21:00"`), when known. Free text
    /// from the provider, so it is displayed only when it parses.
    public var airsTime: String?

    public init(weekdays: [Int] = [], airsTime: String? = nil) {
        self.weekdays = weekdays
        self.airsTime = airsTime
    }

    /// Whether this describes a single, repeating weekday — the only shape that can
    /// honestly be phrased as "New episodes Fridays". A series airing several days a
    /// week, or none, is described by its next date instead.
    public var isSingleWeekday: Bool { weekdays.count == 1 }

    public var isEmpty: Bool { weekdays.isEmpty && airsTime == nil }
}
