import CoreModels

/// Identifies a Home row independently of its content. This is the stable unit
/// the UI renders against and — crucially — the unit a future "customize my
/// rows" feature will reorder/toggle. Keeping identity separate from payload is
/// what lets the loaded view and a (later) skeleton view render from the *same*
/// ordered list, guaranteeing they stay 1:1.
public enum HomeRowKind: String, Hashable, Sendable, CaseIterable {
    case continueWatching
    case watchlist
    case recentlyAdded
    case libraries

    /// The row's display heading.
    public var title: String {
        switch self {
        case .continueWatching: return "Continue Watching"
        case .watchlist: return "Watchlist"
        case .recentlyAdded: return "Recently Added"
        case .libraries: return "Libraries"
        }
    }

    /// Fallback skeleton structure used only on the very first launch (before any
    /// real layout has been persisted). A sensible "most users have these" guess;
    /// once a real load completes, the persisted layout replaces it. The `count: 0`
    /// on each row means "unknown" — the skeleton fills the screen for the current
    /// density until a real load records how many cards each row actually had.
    public static let defaultSkeletonLayout: [HomeRowLayout] = [
        HomeRowLayout(kind: .continueWatching),
        HomeRowLayout(kind: .recentlyAdded),
        HomeRowLayout(kind: .libraries),
    ]
}

/// One persisted Home row descriptor: its `kind` (identity + order + title +
/// style) paired with the number of cards it rendered on the last successful
/// load. The loading skeleton uses `count` to show a *matching* number of
/// placeholders — clamped to what actually fits at the current display density —
/// instead of a fixed guess. That keeps a full row (e.g. Recently Added) filling
/// the screen while a genuinely sparse row (e.g. 3 Continue Watching items) shows
/// just three, so nothing balloons then collapses when real content swaps in.
public struct HomeRowLayout: Hashable, Sendable {
    public let kind: HomeRowKind
    /// Cards the row rendered last load. `0` means "unknown" (first-ever launch or
    /// an older persisted value); the skeleton then fills the screen for the
    /// current density rather than guessing a fixed number.
    public let count: Int

    public init(kind: HomeRowKind, count: Int = 0) {
        self.kind = kind
        self.count = max(count, 0)
    }
}

/// The poster aspect a media row renders with. Mirrors `PosterCardView.Style`
/// but stays SwiftUI-free so the layout model itself is pure and testable on any
/// platform; the view maps it back to the concrete card style.
public enum HomeRowStyle: Sendable, Equatable {
    case poster
    case landscape
}

/// One resolved Home row: its kind (identity + title + style) paired with the
/// content to render. `items` is populated for media rows; `libraries` for the
/// Libraries row. Exactly one of the two is non-empty for any built row.
public struct HomeRow: Identifiable, Equatable, Sendable {
    public let kind: HomeRowKind
    public var items: [MediaItem]
    public var libraries: [AggregatedLibrary]

    public var id: HomeRowKind { kind }
    public var title: String { kind.title }

    /// Continue Watching shows wide landscape stills (resume artwork); every other
    /// media row shows portrait posters.
    public var style: HomeRowStyle { kind == .continueWatching ? .landscape : .poster }

    /// The number of cards this row renders — its media `items` for a media row,
    /// or its `libraries` tiles for the Libraries row (exactly one is populated).
    /// Recorded per row so the next launch's skeleton shows a matching count.
    public var cardCount: Int { max(items.count, libraries.count) }

    init(kind: HomeRowKind, items: [MediaItem] = [], libraries: [AggregatedLibrary] = []) {
        self.kind = kind
        self.items = items
        self.libraries = libraries
    }
}

public extension HomeRow {
    /// Resolves the ordered, visible Home rows from loaded content.
    ///
    /// This makes explicit (and testable) the visibility rules the view used to
    /// apply inline: a media row appears only when it actually has items (matching
    /// `MediaRowView`'s own "hide when empty" behaviour), and the Libraries row
    /// carries only the libraries the visibility model permits and appears only
    /// when at least one survives. The order is fixed for now — Continue Watching,
    /// Watchlist, Recently Added, Libraries — and becomes user-customizable later
    /// by reordering this array.
    ///
    /// `isLibraryVisible` is passed the library's `AggregatedLibrary.key` so the
    /// caller can consult the shared, reactive visibility model; recomputing this
    /// on each render keeps visibility toggles taking effect without a reload.
    ///
    /// Crucially, the same `isLibraryVisible` predicate is applied to the
    /// Continue Watching and Recently Added rows' items via
    /// `MediaItem.isVisibleOnHome(isLibraryVisible:)`, so a hidden library's
    /// movies/episodes are suppressed from those rows too — not just the Libraries
    /// tiles. Items that can't be attributed to a library stay visible
    /// (fail-open), and a merged cross-server card shows if *any* of its
    /// contributing libraries is visible. The **Watchlist** row is intentionally
    /// exempt (see inline note): it's an explicit user save and the Plex watchlist
    /// isn't a per-library list, so hiding a library never drops a watchlisted
    /// title.
    static func rows(
        for content: HomeViewModel.Content,
        isLibraryVisible: (String) -> Bool
    ) -> [HomeRow] {
        var rows: [HomeRow] = []

        let continueWatching = content.continueWatching.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        if !continueWatching.isEmpty {
            rows.append(HomeRow(kind: .continueWatching, items: continueWatching))
        }
        // Watchlist is deliberately NOT library-filtered: it's an explicit user
        // save ("find this later"), and the Plex watchlist is an account-level
        // Discover list that isn't tied to any local library at all. So hiding a
        // library never removes a title the user chose to watchlist. We keep this
        // explicit (rather than relying on watchlist items happening to lack a
        // libraryID) so the guarantee survives even if provenance is added later.
        if !content.watchlist.isEmpty {
            rows.append(HomeRow(kind: .watchlist, items: content.watchlist))
        }
        let latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
        if !latest.isEmpty {
            rows.append(HomeRow(kind: .recentlyAdded, items: latest))
        }

        let visibleLibraries = content.libraries.filter { isLibraryVisible($0.key) }
        if !visibleLibraries.isEmpty {
            rows.append(HomeRow(kind: .libraries, libraries: visibleLibraries))
        }

        return rows
    }
}
