#if os(iOS)
import AniListService
import CoreModels
import MALService
import SimklService
import TraktService

struct PlozziOSTrackerScrobbler: TraktScrobbling {
    let trakt: any TraktScrobbling
    let simkl: any SimklScrobbling
    let anilist: any AniListScrobbling
    let mal: any MALScrobbling

    func scrobble(
        item: MediaItem,
        progress: Double,
        event: PlaybackEvent
    ) async {
        async let traktResult: Void = trakt.scrobble(
            item: item,
            progress: progress,
            event: event
        )
        async let simklResult: Void = simkl.scrobble(
            item: item,
            progress: progress,
            event: event
        )
        async let anilistResult: Void = anilist.scrobble(
            item: item,
            progress: progress,
            event: event
        )
        async let malResult: Void = mal.scrobble(
            item: item,
            progress: progress,
            event: event
        )
        _ = await (traktResult, simklResult, anilistResult, malResult)
    }
}
#endif
