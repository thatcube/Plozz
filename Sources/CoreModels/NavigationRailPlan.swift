import Foundation

/// A top-level destination in the custom navigation rail.
///
/// Unlike the native tab styles — where the four tabs are fixed — the rail treats
/// each of the viewer's libraries as a first-class destination, so a library grid
/// is a *root* screen with chrome rather than a page pushed on top of Home.
public enum NavigationRailDestination: Hashable, Sendable {
    case home
    case search
    case watchlist
    case music
    case settings
    /// A single library, addressed by its ``AggregatedLibrary/key``.
    case library(String)
    /// The synthetic combined browse over every visible library.
    case allLibraries

    /// A stable string form for scene storage.
    public var storageValue: String {
        switch self {
        case .home: return "home"
        case .search: return "search"
        case .watchlist: return "watchlist"
        case .music: return "music"
        case .settings: return "settings"
        case .allLibraries: return "allLibraries"
        case let .library(key): return "library:\(key)"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "home": self = .home
        case "search": self = .search
        case "watchlist": self = .watchlist
        case "music": self = .music
        case "settings": self = .settings
        case "allLibraries": self = .allLibraries
        default:
            guard storageValue.hasPrefix("library:") else { return nil }
            self = .library(String(storageValue.dropFirst("library:".count)))
        }
    }
}

/// One library slot in the rail: either a real library or the synthetic
/// "All Libraries" entry.
public struct NavigationRailLibraryEntry: Hashable, Sendable, Identifiable {
    /// The arrangement key — an ``AggregatedLibrary/key``, or
    /// ``NavigationLibraryLayout/allLibrariesKey`` for the combined entry.
    public let key: String
    /// The backing library; `nil` for the combined "All Libraries" entry.
    public let library: AggregatedLibrary?

    public init(key: String, library: AggregatedLibrary?) {
        self.key = key
        self.library = library
    }

    public var id: String { key }

    /// Whether this is the synthetic combined entry.
    public var isAllLibraries: Bool { library == nil }

    public var destination: NavigationRailDestination {
        library == nil ? .allLibraries : .library(key)
    }
}

/// Pure resolution of the rail's library slots from the live library set plus the
/// profile's saved arrangement. SwiftUI-free so the ordering/visibility rules are
/// unit-testable without a running view hierarchy.
public enum NavigationRailPlan {
    /// Every key the viewer can arrange right now: the combined entry first, then
    /// each visible (non-music) library in discovery order.
    ///
    /// Music libraries are excluded deliberately: music has its own destination
    /// (and its own landing screen), so listing an artist section beside the video
    /// libraries would open a video grid over music content.
    public static func availableKeys(visibleLibraries: [AggregatedLibrary]) -> [String] {
        [NavigationLibraryLayout.allLibrariesKey] + browsableLibraries(visibleLibraries).map(\.key)
    }

    /// The libraries the rail can offer: everything that is not a music library.
    public static func browsableLibraries(_ libraries: [AggregatedLibrary]) -> [AggregatedLibrary] {
        libraries.filter { !$0.library.isMusic }
    }

    /// The rail's library slots, in the viewer's order, with hidden entries removed.
    public static func entries(
        visibleLibraries: [AggregatedLibrary],
        layout: NavigationLibraryLayout
    ) -> [NavigationRailLibraryEntry] {
        let browsable = browsableLibraries(visibleLibraries)
        let byKey = Dictionary(browsable.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let available = availableKeys(visibleLibraries: visibleLibraries)
        return layout.visibleKeys(available: available).compactMap { key in
            if key == NavigationLibraryLayout.allLibrariesKey {
                // The combined entry is pointless with nothing to combine, and
                // actively misleading with exactly one library (it would be a
                // duplicate of that library's own slot).
                guard browsable.count > 1 else { return nil }
                return NavigationRailLibraryEntry(key: key, library: nil)
            }
            guard let library = byKey[key] else { return nil }
            return NavigationRailLibraryEntry(key: key, library: library)
        }
    }

    /// Resolves a selected destination back to a still-valid one, so a library that
    /// has been hidden, removed, or signed out of can never leave the rail pointing
    /// at a destination with nothing to render.
    public static func resolvedSelection(
        _ selection: NavigationRailDestination,
        entries: [NavigationRailLibraryEntry],
        showsWatchlist: Bool,
        showsMusic: Bool
    ) -> NavigationRailDestination {
        switch selection {
        case .home, .search, .settings:
            return selection
        case .watchlist:
            return showsWatchlist ? .watchlist : .home
        case .music:
            return showsMusic ? .music : .home
        case .allLibraries:
            return entries.contains(where: \.isAllLibraries) ? .allLibraries : .home
        case let .library(key):
            return entries.contains(where: { $0.key == key }) ? selection : .home
        }
    }
}
