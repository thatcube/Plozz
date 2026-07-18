#if canImport(SwiftUI)
import CoreModels
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

/// Bundle of the user-scoped sync + external-ratings services threaded down the
/// tab hierarchy. A read-only value grouping the seven service references that
/// `MainTabView` (and its Home/Search tabs) consume, so the memberwise init — and
/// its `RootView` construction site — pass ONE grouped value instead of seven
/// separate args. Same instances, no behavior change.
struct SyncServices {
    let ratingsProvider: any ExternalRatingsProviding
    let trakt: TraktService
    let simkl: SimklService
    let seer: SeerService
    let anilist: AniListService
    let mal: MALService
    let lastfm: LastFmService
}
#endif
