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

/// Bundles the watch-outbox interactions the full-screen player needs: live-
/// session registration (so the convergence reconciler defers writes against the
/// server currently streaming) plus the durable final convergence enqueue. Passed
/// down the tab hierarchy in place of a bare enqueue closure so the player can
/// both guard and converge through one value.
struct WatchOutboxBridge: Sendable {
    /// Register `(accountID, itemID)` as the live in-app session (idempotent).
    let beginLiveSession: @Sendable (_ accountID: String, _ itemID: String) -> Void
    /// End the live session for `(accountID, itemID)` and enqueue the optional
    /// final convergence `mutation`, in that order, so the just-played server is
    /// no longer deferred and its resume/played write goes out. `watchedPercent`
    /// (0...100) is the fraction watched at stop, used to drive the optimistic
    /// in-UI progress update (the resume bar on the surface the user returns to).
    let finishPlayback: @Sendable (_ accountID: String?, _ itemID: String, _ watchedPercent: Double, _ mutation: WatchMutation?) -> Void
    /// Durably enqueue a mid-play convergence `mutation` without ending the live
    /// session, so progress fans out to the **other** servers (the launch server
    /// stays deferred while it plays). Pure local enqueue + drain — no network on
    /// the caller's path.
    let checkpoint: @Sendable (_ mutation: WatchMutation) -> Void
    /// Live, off-main read of the active profile's "sync watch state across
    /// servers" preference, evaluated at stop/checkpoint time (not captured at
    /// player start) so flipping the toggle mid-playback takes effect on the next
    /// convergence. Backed by a thread-safe UserDefaults read.
    let crossServerSync: @Sendable () -> Bool
}
#endif
