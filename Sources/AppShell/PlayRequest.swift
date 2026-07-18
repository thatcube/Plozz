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

/// A fully-resolved request to present the player for an item at an explicit
/// start position (seconds). `startPosition` of `0` means "start over".
struct PlayRequest: Identifiable, Equatable {
    let item: MediaItem
    let startPosition: TimeInterval
    let traceID: UUID
    let requestedAt: Date

    init(
        item: MediaItem,
        startPosition: TimeInterval,
        traceID: UUID = UUID(),
        requestedAt: Date = Date()
    ) {
        self.item = item
        self.startPosition = startPosition
        self.traceID = traceID
        self.requestedAt = requestedAt
    }

    var id: String { item.id }
}
#endif
