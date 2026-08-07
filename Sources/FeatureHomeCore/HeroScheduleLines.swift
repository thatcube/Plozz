import Foundation
import CoreModels
import CoreNetworking
import MetadataKit

/// The air-schedule line for each series in the Home hero, keyed by item id.
///
/// A schedule is only cached once something asks for it, and until now the only
/// thing that asked was opening a series. So the badge that works on a detail page
/// was permanently blank on Home — which is where most people would actually see
/// it, since the hero is the first thing on screen.
///
/// Deliberately bounded rather than eager. Everything already known is published
/// without a single request, and only the slide actually on screen is fetched. The
/// carousel advances by itself, so the rest fill in as they front instead of firing
/// a burst of requests at first paint, when Home has better things to do.
@MainActor
@Observable
public final class HeroScheduleLines {
    /// Rendered lines by item id. Only series that have something truthful to say
    /// appear here, so a missing entry means "no badge" rather than "not loaded".
    public private(set) var lines: [String: LocalizedStringResource] = [:]

    /// Metadata identities already sent to the network. Re-fronting a slide is normal in a
    /// carousel — the same three or four come round repeatedly — and without this
    /// each pass would re-request a schedule the resolver has already answered.
    private var fetched: Set<String> = []
    /// Requests currently running. A fronted slide can disappear before its
    /// provider chain finishes; cancellation must clear this set so the next visit
    /// retries instead of treating an incomplete refresh as fetched forever.
    private var fetching: Set<String> = []

    public init() {}

    public func line(for item: MediaItem) -> LocalizedStringResource? {
        lines[item.id]
    }

    /// Changes when a slide with the same card id gains external provider ids.
    /// Initial Home slides can front before metadata enrichment lands; keying the
    /// task only by `item.id` permanently cached that first unresolvable attempt.
    public func fetchKey(for item: MediaItem?) -> String {
        guard let item else { return "-" }
        let identity = MetadataQuery(item).seriesScoped.enrichmentCacheKey
        return "\(item.id)|\(identity)"
    }

    /// Publishes every schedule already on disk for `items`. **Zero network**, so
    /// this is safe to run on every hero build and gives a returning viewer their
    /// badges on the first frame.
    public func loadCached(_ items: [MediaItem]) async {
        for item in items where Self.carriesSchedule(item) {
            guard lines[item.id] == nil else { continue }
            let record = await SeriesScheduleResolver.shared.cachedRecord(for: MetadataQuery(item).seriesScoped)
            guard let line = Self.cachedLine(from: record) else { continue }
            lines[item.id] = line
        }
    }

    /// Ensures the slide on screen has a schedule, fetching one if it isn't cached.
    ///
    /// The resolver short-circuits on a fresh record, so a repeat visit costs
    /// nothing; `fetched` covers the rest, where a stale record would otherwise be
    /// re-requested every time the carousel came back round.
    public func refreshFronted(_ item: MediaItem) async {
        let fetchKey = fetchKey(for: item)
        if Self.carriesExternalAvailability(item) {
            // The resolver owns positive/negative TTLs. Re-entering the slide is
            // a cheap actor/cache hit and becomes a real refresh only when due.
            let availability =
                await ExternalTitleMetadataResolver.shared.availability(
                    for: item,
                    regionCode:
                        Locale.current.region?.identifier ?? "US"
                )
            let line = availability.primaryLine()
            PlozzLog.boot(
                "HeroAvailability title=\(item.title) key=\(fetchKey) "
                    + "offers=\(availability.watchOffers.count) "
                    + "events=\(availability.releaseEvents.count) "
                    + "line=\(line == nil ? "no" : "yes")"
            )
            if lines[item.id] != line {
                lines[item.id] = line
            }
            // A current watch offer ("Streaming on Apple TV") is more useful
            // than a series cadence. With no availability line, fall through to
            // the existing multi-provider TV schedule.
            if line != nil || !Self.carriesSchedule(item) { return }
        }
        guard Self.carriesSchedule(item) else { return }
        guard !fetched.contains(fetchKey), fetching.insert(fetchKey).inserted else {
            return
        }
        defer { fetching.remove(fetchKey) }
        let query = MetadataQuery(item).seriesScoped
        // The viewer is looking at this slide right now, so it goes ahead of the
        // passive backlog — the same tier a detail page uses.
        let record = await SeriesScheduleResolver.shared.refresh(query, tier: .foregroundFill)
        guard !Task.isCancelled else { return }
        fetched.insert(fetchKey)
        apply(record, to: item)
    }

    private func apply(_ record: SeriesScheduleRecord?, to item: MediaItem) {
        guard let record else { return }
        let line = SeriesUpcoming.heroLine(
            nextEpisode: record.upcomingEpisode,
            cadence: record.cadence,
            schedule: record.upcomingEpisodes
        )
        guard lines[item.id] != line else { return }
        lines[item.id] = line
    }

    /// Fresh cache entries can paint immediately. Expired entries stay hidden
    /// until ``refreshFronted(_:)`` confirms them, preventing an old cadence from
    /// flashing for a moment and then disappearing when the refresh returns.
    static func cachedLine(
        from record: SeriesScheduleRecord?,
        now: Date = Date()
    ) -> LocalizedStringResource? {
        guard let record, !record.isRefreshDue(now: now) else { return nil }
        return SeriesUpcoming.heroLine(
            nextEpisode: record.upcomingEpisode,
            cadence: record.cadence,
            schedule: record.upcomingEpisodes,
            now: now
        )
    }

    /// Whether an item can have an air schedule at all.
    ///
    /// Episodes count: a Continue Watching slide *is* an episode, and that is the
    /// single most common way a show reaches the hero — excluding them left the
    /// badge missing from exactly the slides most likely to want it. The query is
    /// series-scoped before use, so an episode and its show share one answer.
    ///
    /// Movies are out: a film has no next episode, and asking spends a request to
    /// be told so.
    static func carriesSchedule(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .series, .season, .episode: return true
        default: return false
        }
    }

    static func carriesExternalAvailability(_ item: MediaItem) -> Bool {
        item.isNotInLibraryDiscovery
            && (item.kind == .movie
                || item.kind == .video
                || item.kind == .series)
    }
}
