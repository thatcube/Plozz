import Foundation
import CoreModels
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
    public private(set) var lines: [String: String] = [:]

    /// Items already sent to the network. Re-fronting a slide is normal in a
    /// carousel — the same three or four come round repeatedly — and without this
    /// each pass would re-request a schedule the resolver has already answered.
    private var fetched: Set<String> = []

    public init() {}

    public func line(for item: MediaItem) -> String? { lines[item.id] }

    /// Publishes every schedule already on disk for `items`. **Zero network**, so
    /// this is safe to run on every hero build and gives a returning viewer their
    /// badges on the first frame.
    public func loadCached(_ items: [MediaItem]) async {
        for item in items where Self.carriesSchedule(item) {
            guard lines[item.id] == nil else { continue }
            let record = await SeriesScheduleResolver.shared.cachedRecord(for: MetadataQuery(item).seriesScoped)
            apply(record, to: item)
        }
    }

    /// Ensures the slide on screen has a schedule, fetching one if it isn't cached.
    ///
    /// The resolver short-circuits on a fresh record, so a repeat visit costs
    /// nothing; `fetched` covers the rest, where a stale record would otherwise be
    /// re-requested every time the carousel came back round.
    public func refreshFronted(_ item: MediaItem) async {
        guard Self.carriesSchedule(item), fetched.insert(item.id).inserted else { return }
        let query = MetadataQuery(item).seriesScoped
        // The viewer is looking at this slide right now, so it goes ahead of the
        // passive backlog — the same tier a detail page uses.
        let record = await SeriesScheduleResolver.shared.refresh(query, tier: .foregroundFill)
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
}
