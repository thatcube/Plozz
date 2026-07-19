import Foundation

/// Everything needed to derive a series' schedule state for the Home rows, assembled
/// by the caller from **cached** inputs only (the schedule store + the already-loaded
/// merged library), so building the rows touches no network.
public struct SeriesScheduleContext: Sendable {
    /// The owned series card to show in the row.
    public let series: MediaItem
    /// The cached next-episode schedule for the series (`nil` -> no schedule known).
    public let upcoming: UpcomingEpisode?
    /// The user's owned episodes for the series, across all sources.
    public let presence: EpisodePresenceIndex
    /// Seerr's status for the scheduled episode's season, when configured.
    public let seerStatus: MediaAvailabilityStatus?

    public init(
        series: MediaItem,
        upcoming: UpcomingEpisode?,
        presence: EpisodePresenceIndex,
        seerStatus: MediaAvailabilityStatus? = nil
    ) {
        self.series = series
        self.upcoming = upcoming
        self.presence = presence
        self.seerStatus = seerStatus
    }
}

/// One classified series for a Home schedule row.
public struct SeriesScheduleEntry: Sendable, Equatable {
    public let series: MediaItem
    public let state: EpisodeReleaseState

    public init(series: MediaItem, state: EpisodeReleaseState) {
        self.series = series
        self.state = state
    }
}

/// Builds the optional Home "Airing Soon" and "Recently Aired — Missing" rows from
/// cached schedule contexts.
///
/// - **Airing Soon:** owned series whose next known episode is still in the future and
///   not yet owned, soonest first.
/// - **Recently Aired — Missing:** series whose next known episode has aired (past its
///   grace window) and is absent from every source, most-recently-aired first. A
///   season Seerr already has in flight reflects as `.requested`, so it is *not*
///   listed as missing.
///
/// Grace-period ("aired today") and present/requested series appear in neither row —
/// they surface on the series detail page instead. Pure and cache-only: the caller
/// passes contexts assembled from the store + loaded library, so this does no I/O.
public enum HomeScheduleRowBuilder {
    public static func rows(
        from contexts: [SeriesScheduleContext],
        now: Date = Date(),
        grace: EpisodeGraceConfig = .default
    ) -> (airingSoon: [SeriesScheduleEntry], recentlyAiredMissing: [SeriesScheduleEntry]) {
        var airingSoon: [(entry: SeriesScheduleEntry, airDate: Date)] = []
        var missing: [(entry: SeriesScheduleEntry, airDate: Date)] = []

        for context in contexts {
            guard let state = EpisodeReleaseStateMachine.state(
                upcoming: context.upcoming,
                presence: context.presence,
                seerStatus: context.seerStatus,
                now: now,
                grace: grace
            ) else { continue }

            let entry = SeriesScheduleEntry(series: context.series, state: state)
            switch state {
            case .upcoming(let e):
                airingSoon.append((entry, e.airDate))
            case .airedMissing(let e):
                missing.append((entry, e.airDate))
            case .airedGracePeriod, .requested, .present:
                continue
            }
        }

        airingSoon.sort { $0.airDate < $1.airDate }   // soonest first
        missing.sort { $0.airDate > $1.airDate }      // most recently aired first
        return (airingSoon.map(\.entry), missing.map(\.entry))
    }
}
