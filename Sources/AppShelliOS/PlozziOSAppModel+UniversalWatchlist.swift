#if os(iOS)
import AppRuntime
import CoreModels
import FeatureWatchlistCore
import Foundation

/// iOS/iPadOS adapter onto the shared ``UniversalWatchlistHost`` runtime — see the
/// tvOS adapter for why the logic itself lives in `AppRuntime` rather than here.
extension PlozziOSAppModel: UniversalWatchlistHost {
    static func universalWatchlistStorageDirectory() -> URL? {
        writableStateDirectory()?
            .appendingPathComponent("PlozzMediaState", isDirectory: true)
            .appendingPathComponent("Watchlist", isDirectory: true)
    }

    var universalWatchlistStorageDirectory: URL? {
        Self.universalWatchlistStorageDirectory()
    }

    func plexDiscoverToken(forAccount accountID: String) -> String? {
        plexHomeUsers.discoverToken(for: accountID)
    }

    var trackerWatchlistDestinations: [any WatchlistDestination] {
        // Peers, not a fallback chain: a viewer may sync to both, and
        // one service being unconfigured or unusable must not affect the
        // other.
        let candidates: [(any WatchlistDestination)?] = [
            traktService.watchlistDestination,
            simklService.watchlistDestination,
            anilistService.watchlistDestination,
            malService.watchlistDestination,
        ]
        return candidates.compactMap { $0 }
    }
}
#endif
