import Foundation

/// An index of the episodes a user already owns for one series, across every source,
/// used to decide whether a scheduled episode is already present.
///
/// ## Numbering is kept strictly separate (never converted)
/// Western TV episodes are matched on `(season, episode)`; anime schedules (which
/// arrive as an **absolute** counter) are matched against owned episodes stored in a
/// *flat* layout (no season, or season 1) whose episode number IS the absolute
/// number. An absolute number is **never** derived by summing prior seasons' counts —
/// providers disagree on season boundaries, so a multi-season anime whose schedule is
/// absolute simply won't number-match (the safe failure the Step 8 plan mandates),
/// rather than risk a wrong "already owned"/"missing" verdict.
public struct EpisodePresenceIndex: Sendable, Equatable {
    /// A `(season, episode)` coordinate.
    public struct SeasonEpisode: Hashable, Sendable {
        public let season: Int
        public let episode: Int
        public init(season: Int, episode: Int) {
            self.season = season
            self.episode = episode
        }
    }

    private var seasonEpisodeItems: [SeasonEpisode: MediaItem]
    private var absoluteItems: [Int: MediaItem]

    /// Builds the index from every owned episode of a series (duplicates across
    /// sources are fine — the first seen for a coordinate wins).
    public init(ownedEpisodes: [MediaItem]) {
        var seasonEpisode: [SeasonEpisode: MediaItem] = [:]
        var absolute: [Int: MediaItem] = [:]
        for episode in ownedEpisodes where episode.kind == .episode {
            if let s = episode.seasonNumber, let e = episode.episodeNumber {
                let key = SeasonEpisode(season: s, episode: e)
                if seasonEpisode[key] == nil { seasonEpisode[key] = episode }
            }
            // Flat-layout absolute bridge: an episode with no season (or season 1)
            // exposes its episode number as an absolute counter. This reads a number
            // that is already absolute — it is NOT a cross-season conversion.
            if let e = episode.episodeNumber, episode.seasonNumber == nil || episode.seasonNumber == 1 {
                if absolute[e] == nil { absolute[e] = episode }
            }
        }
        self.seasonEpisodeItems = seasonEpisode
        self.absoluteItems = absolute
    }

    /// The owned episode matching `upcoming`, or `nil` when it is not present.
    ///
    /// Matches on the numbering the schedule actually carries: an absolute-numbered
    /// schedule only ever consults the absolute set; a per-season schedule only ever
    /// consults the `(season, episode)` set. A schedule with neither form can't be
    /// number-matched and returns `nil`.
    public func presentItem(for upcoming: UpcomingEpisode) -> MediaItem? {
        if let absolute = upcoming.absoluteEpisodeNumber {
            return absoluteItems[absolute]
        }
        if let season = upcoming.seasonNumber, let episode = upcoming.episodeNumber {
            return seasonEpisodeItems[SeasonEpisode(season: season, episode: episode)]
        }
        return nil
    }

    public var isEmpty: Bool { seasonEpisodeItems.isEmpty && absoluteItems.isEmpty }
}

/// How long after an episode's air time it is shown as "just aired" before being
/// flagged as missing.
public struct EpisodeGraceConfig: Sendable {
    /// Grace after an exact air *timestamp* (default 6h) — lets a just-aired episode
    /// propagate to the user's sources before it reads as missing.
    public var exactGrace: TimeInterval
    /// The calendar used to compute the "following local day" boundary for a
    /// date-only schedule.
    public var calendar: Calendar

    public init(exactGrace: TimeInterval = 6 * 60 * 60, calendar: Calendar = .current) {
        self.exactGrace = exactGrace
        self.calendar = calendar
    }

    public static let `default` = EpisodeGraceConfig()

    /// The instant at which `upcoming` stops being "just aired" and becomes missing.
    /// For an exact timestamp: `airDate + exactGrace`. For a date-only schedule: the
    /// start of the **following** local day (so it reads "aired today" all air day).
    public func missingThreshold(for upcoming: UpcomingEpisode) -> Date {
        switch upcoming.datePrecision {
        case .dateAndTime:
            return upcoming.airDate.addingTimeInterval(exactGrace)
        case .dateOnly:
            let startOfAirDay = calendar.startOfDay(for: upcoming.airDate)
            return calendar.date(byAdding: .day, value: 1, to: startOfAirDay) ?? startOfAirDay
        }
    }
}

/// Derives an ``EpisodeReleaseState`` from a schedule + what the user owns (+ an
/// optional Seerr reflection). Pure and cheap, so it can be recomputed on every
/// server refresh / share scan and on every render from cached inputs.
public enum EpisodeReleaseStateMachine {
    /// Derives the release state for one series' next known episode.
    ///
    /// - Parameters:
    ///   - upcoming: The cached schedule, or `nil` when none is known.
    ///   - presence: The user's owned episodes for the series, across all sources.
    ///   - seerStatus: Seerr's request/availability for the season/episode, when
    ///     configured (Phase 3). `nil` means Seerr is not consulted.
    ///   - now: The current instant (injected for testing).
    ///   - grace: Grace-period configuration.
    /// - Returns: The derived state, or `nil` when there is nothing to surface (no
    ///   schedule and the episode isn't present).
    ///
    /// Precedence, in order:
    /// 1. **Present anywhere** → `.present` (no further schedule lookup; once owned it
    ///    never reverts to a schedule state).
    /// 2. No schedule → `nil`.
    /// 3. Seerr says requested/processing → `.requested` (shown instead of missing).
    /// 4. Future air time → `.upcoming`.
    /// 5. Aired, within grace → `.airedGracePeriod`.
    /// 6. Aired, grace elapsed → `.airedMissing`.
    public static func state(
        upcoming: UpcomingEpisode?,
        presence: EpisodePresenceIndex,
        seerStatus: MediaAvailabilityStatus? = nil,
        now: Date = Date(),
        grace: EpisodeGraceConfig = .default
    ) -> EpisodeReleaseState? {
        // 1. Presence wins over any schedule state.
        if let upcoming, let owned = presence.presentItem(for: upcoming) {
            return .present(item: owned)
        }
        // 2. No schedule and not present → nothing to show.
        guard let upcoming else { return nil }

        // 3. Seerr reflection (never auto-acts): an in-flight request replaces
        //    "missing" with "requested/processing".
        if let seerStatus, Self.reflectsRequest(seerStatus) {
            return .requested(upcoming)
        }

        // 4–6. Air-time driven.
        if now < upcoming.airDate {
            return .upcoming(upcoming)
        }
        return now < grace.missingThreshold(for: upcoming)
            ? .airedGracePeriod(upcoming)
            : .airedMissing(upcoming)
    }

    /// Whether a Seerr availability status represents an in-flight request that should
    /// be reflected as `.requested` rather than a missing episode. Available/deleted/
    /// unknown do not (available becomes `.present` via the library; the rest fall
    /// through to the normal air-time logic).
    static func reflectsRequest(_ status: MediaAvailabilityStatus) -> Bool {
        switch status {
        case .pending, .processing, .partiallyAvailable:
            return true
        case .unknown, .available, .deleted:
            return false
        }
    }
}
