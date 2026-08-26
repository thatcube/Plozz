import Foundation

/// What belongs in Continue Watching, and how long a loaded row may be trusted.
///
/// The row is assembled from whatever each backend calls "resume", and those
/// feeds do not agree with each other or, in some cases, with the server's own
/// screen. Two habits in particular put titles on the row that the viewer has
/// finished with:
///
///  - Backends volunteer **next-up suggestions** — an unwatched next episode
///    offered because a previous one was watched. Useful for a show being
///    followed; noise for one abandoned months ago. Plex's Continue Watching hub
///    retires these on its own, Jellyfin bounds them with a server setting that
///    defaults to a full year, and neither is visible to the other.
///  - A feed is only as current as the last time it was asked, which is why the
///    row also needs to know when it has gone stale.
///
/// Keeping the rules here means every provider and both shells apply the same
/// ones, and changing them later is a change to this type rather than a hunt
/// through five call sites.
public struct ContinueWatchingPolicy: Sendable, Equatable, Codable {
    /// How many titles the row carries.
    ///
    /// Applied per account and again to the merged result, so with several
    /// servers the accounts compete for these slots. The previous value of 20 was
    /// a placeholder: a single real library can hold more in-progress titles than
    /// that, and everything past the cut simply vanished with no way to reach it.
    public var rowLimit: Int

    /// How long a **next-up suggestion** stays on the row after the last time
    /// anything in its series was played. `nil` keeps them forever.
    ///
    /// Deliberately does not apply to genuinely in-progress titles. Something
    /// stopped halfway is a promise to come back, however long ago it was made,
    /// and dropping it is how a viewer loses their place in a long film they
    /// return to twice a year. A suggestion carries no such promise: nothing was
    /// started, and the series has been untouched since.
    public var nextUpCutoff: TimeInterval?

    /// How old loaded Home content may be before returning to Home refreshes it.
    ///
    /// Home cannot see a title watched, finished or dismissed on another device,
    /// because nothing tells it to look. Without a bound it will keep showing the
    /// row it built at launch for as long as the app stays open. The window has
    /// to be long enough that stepping into a title and straight back out is not
    /// a refetch — that is ordinary navigation, and reloading there costs a
    /// visible reshuffle for no new information.
    public var refreshAfter: TimeInterval

    public init(
        rowLimit: Int = 60,
        nextUpCutoff: TimeInterval? = 90 * 24 * 60 * 60,
        refreshAfter: TimeInterval = 90
    ) {
        self.rowLimit = max(1, rowLimit)
        self.nextUpCutoff = nextUpCutoff
        self.refreshAfter = max(0, refreshAfter)
    }

    public static let `default` = ContinueWatchingPolicy()

    /// Everything kept, with no age bound. For tests that care about ordering
    /// rather than curation, and as the honest way to express "keep it all".
    public static let unbounded = ContinueWatchingPolicy(rowLimit: .max, nextUpCutoff: nil)

    /// Whether a title still belongs on the row.
    ///
    /// **Fail-open by construction.** A title is dropped only when it is known to
    /// be a suggestion *and* known to be old. Anything in progress, and anything
    /// whose recency a backend did not report, is kept — a missing timestamp is an
    /// absence of evidence, and guessing from it would quietly delete a title the
    /// viewer is halfway through.
    public func keeps(_ item: MediaItem, now: Date = Date()) -> Bool {
        guard let nextUpCutoff else { return true }
        // Started, therefore a promise to come back. Age is irrelevant.
        if (item.resumePosition ?? 0) > 0 { return true }
        // A suggestion. Providers stamp these with their series' last-played date
        // precisely so the row can order them; the same stamp bounds them here.
        guard let lastPlayedAt = item.lastPlayedAt else { return true }
        return now.timeIntervalSince(lastPlayedAt) <= nextUpCutoff
    }

    /// One account's resume feed, curated. Applied **before** the cross-account
    /// merge so the row's limited slots are filled with titles worth showing
    /// rather than spent on suggestions that are about to be dropped.
    public func curated(_ items: [MediaItem], now: Date = Date()) -> [MediaItem] {
        guard nextUpCutoff != nil else { return items }
        return items.filter { keeps($0, now: now) }
    }
}
