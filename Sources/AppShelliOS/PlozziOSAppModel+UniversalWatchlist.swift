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

    var traktWatchlistDestination: (any WatchlistDestination)? {
        traktService.watchlistDestination
    }
}
#endif
