#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureMusic
import SwiftUI

/// Reads the music-availability model **inside the Music tab** and builds
/// ``MusicTabView`` from it.
///
/// The point is where the reading happens. `MainTabView` used to unpack
/// `detectedAccounts` and `visibleLibraryIDs` in its own body to pass them down,
/// which made the entire tab tree a subscriber of those properties. They are
/// filled in once, shortly after launch, by the availability cache seed — and
/// that single write re-ran `MainTabView.body`, reset the Home tab's identity
/// and threw away its `@State`, restarting a four-account Home load that was
/// already 2.5 seconds in. Every cold launch therefore did the whole thing
/// twice.
///
/// Holding the model as a plain `let` and reading it one level down keeps the
/// invalidation where it belongs: this small view, and nothing else.
struct MusicAvailabilityScope: View {
    let availability: MusicAvailabilityModel
    let controller: AudioPlaybackController
    let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    let appTheme: AppTheme
    let musicPlayer: MusicPlayerSettingsModel
    @Binding var showNowPlaying: Bool

    var body: some View {
        MusicTabView(
            accounts: availability.detectedAccounts,
            visibleLibraryIDs: availability.visibleLibraryIDs,
            controller: controller,
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            appTheme: appTheme,
            musicPlayer: musicPlayer,
            showNowPlaying: $showNowPlaying
        )
    }
}
#endif
