#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

/// Real-time scrobble fan-out injected into the player. Conforms to
/// `TraktScrobbling` (the type the player expects) but forwards every
/// start/pause/stop event to **both** Trakt and Simkl so each shows "Now
/// Watching" the instant playback begins. Other trackers (MAL/AniList) have no
/// real-time now-watching API, so they continue to converge on stop via the
/// durable watch-state outbox. Best-effort: errors never reach playback.
struct RealtimePlaybackScrobbler: TraktScrobbling {
    let trakt: any TraktScrobbling
    let simkl: any SimklScrobbling

    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        await trakt.scrobble(item: item, progress: progress, event: event)
        await simkl.scrobble(item: item, progress: progress, event: event)
    }
}
#endif
