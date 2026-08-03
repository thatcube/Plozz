import AppRuntime
import CoreModels
import FeatureWatchlistCore
import Foundation

/// tvOS adapter onto the shared ``UniversalWatchlistHost`` runtime. Everything the
/// watchlist actually *does* — alias resolution, fan-out, native import, identity
/// reconciliation — lives once in `AppRuntime`; this file only says where the tvOS
/// shell keeps its pieces.
extension AppState: UniversalWatchlistHost {
    static func universalWatchlistStorageDirectory() -> URL? {
        writableStateDirectory()?
            .appendingPathComponent("PlozzMediaState", isDirectory: true)
            .appendingPathComponent("Watchlist", isDirectory: true)
    }

    public var universalWatchlistStorageDirectory: URL? {
        Self.universalWatchlistStorageDirectory()
    }

    public var profiles: ProfilesModel { profilesModel }

    public var trackerWatchlistDestinations: [any WatchlistDestination] {
        // Peers, not a fallback chain: a viewer may sync to both, and
        // one service being unconfigured or unusable must not affect the
        // other.
        let candidates: [(any WatchlistDestination)?] = [
            traktService.watchlistDestination,
            simklService.watchlistDestination,
        ]
        return candidates.compactMap { $0 }
    }
}
