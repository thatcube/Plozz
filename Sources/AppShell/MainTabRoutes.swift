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

/// A navigation value for opening an item's detail page **from a library tile**,
/// carrying the library's owning `Account.id` so the detail/playback default to
/// that server's copy (the cross-server picker still lets the user switch). Home
/// and Search push the bare ``MediaItem`` instead, which keeps the smart
/// best-version default.
struct LibraryDetailRoute: Hashable {
    let item: MediaItem
    /// The owning `Account.id` of the library this item was opened from, or `nil`
    /// when the origin can't be resolved (then the detail falls back to best).
    let originAccountID: String?
}

/// A navigation value for opening a person page.
///
/// Carries the account the person was seen on, because credits are answered by
/// that source's own server using its own person id — and a bare id is not
/// globally unique across servers, so this must never resolve through the
/// cross-server aggregate (see `AggregatedLibraryProvider.item(id:)`).
struct PersonRoute: Hashable {
    let person: MediaPerson
    /// The owning `Account.id` of the item this person was listed on, or `nil`
    /// when it can't be resolved (then the page shows no library credits).
    let sourceAccountID: String?
}

/// A navigation value for opening a *series* page focused on one of its
/// episodes. Tapping a lone episode (e.g. from "Recently Added") routes through
/// this instead of pushing the episode itself, so the user always lands on the
/// rich series/season page — with the tapped episode fronted in the hero, its
/// season selected, the episode row pre-scrolled to it, and Play focused at the
/// top — rather than a dead-end single-episode page.
struct EpisodeContextRoute: Hashable {
    let episode: MediaItem
    let originAccountID: String?
    /// The owning series' id (falls back to the episode id only if unset, which
    /// shouldn't happen for an episode that carries a `seriesID`).
    var seriesID: String { episode.seriesID ?? episode.id }
    var sourceAccountID: String? { episode.sourceAccountID }
}

/// A navigation value for opening a *series* page focused on a specific season.
/// Tapping a season item (e.g. from "Recently Added") routes through this instead
/// of pushing the season itself, so the user always lands on the rich series page —
/// with the tapped season selected, and the "next up" episode for that season
/// fronted in the hero.
struct SeasonContextRoute: Hashable {
    let season: MediaItem
    let originAccountID: String?
    /// The owning series' id.
    var seriesID: String { season.seriesID ?? season.id }
    var sourceAccountID: String? { season.sourceAccountID }
}
#endif
