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
    static func rows(
        for content: HomeViewModel.Content,
        isLibraryVisible: (String) -> Bool
    ) -> [HomeRow] {
        var rows: [HomeRow] = []

        if !content.continueWatching.isEmpty {
            rows.append(HomeRow(kind: .continueWatching, items: content.continueWatching))
        }
        if !content.watchlist.isEmpty {
            rows.append(HomeRow(kind: .watchlist, items: content.watchlist))
        }
        if !content.latest.isEmpty {
            rows.append(HomeRow(kind: .recentlyAdded, items: content.latest))
        }

        let visibleLibraries = content.libraries.filter { isLibraryVisible($0.key) }
        if !visibleLibraries.isEmpty {
            rows.append(HomeRow(kind: .libraries, libraries: visibleLibraries))
        }

        return rows
    }
}
