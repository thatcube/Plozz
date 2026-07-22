import Foundation

/// Reflects Seerr's request/availability coverage onto a series' scheduled episode —
/// **reflection only**. It decides how an upcoming/missing episode should read when
/// Seerr is configured (Requested/Processing instead of Missing) and *which* season a
/// user could hand to the existing request control, but it never itself requests or
/// downloads anything.
public enum SeriesScheduleSeerReflection {
    /// The Seerr availability status that applies to `upcoming`'s season, for the
    /// release-state machine's `seerStatus`.
    ///
    /// - Returns `nil` when Seerr isn't configured (`availability == nil`) so the
    ///   schedule/missing info still shows with no request state at all.
    /// - Prefers the tracked season matching `upcoming.seasonNumber`; falls back to
    ///   the series-level status when there's no per-season match (e.g. an
    ///   absolute-numbered anime with no season, or a season Seerr doesn't track).
    public static func seerStatus(
        for upcoming: UpcomingEpisode,
        availability: MediaRequestAvailability?
    ) -> MediaAvailabilityStatus? {
        guard let availability else { return nil }
        if let season = upcoming.seasonNumber,
           let match = availability.seasons.first(where: { $0.number == season }) {
            return match.status
        }
        return availability.status
    }

    /// The season number to feed into the **existing** `onRequestSeasons` control for
    /// a missing scheduled episode — only when that season is genuinely requestable.
    ///
    /// Returns `nil` (offer nothing) when Seerr isn't configured, the schedule has no
    /// season (absolute-numbered anime), the season isn't tracked, or it is already
    /// in flight / available. Deciding *which* season is requestable is all this does;
    /// it never invokes a request — the user must act.
    public static func requestableMissingSeason(
        for upcoming: UpcomingEpisode,
        availability: MediaRequestAvailability?
    ) -> Int? {
        guard let availability, let season = upcoming.seasonNumber,
              let match = availability.seasons.first(where: { $0.number == season }) else {
            return nil
        }
        return match.isRequestable ? season : nil
    }
}
