import CoreModels
import FeaturePlayback
import Foundation

/// Seeds a media share from the environment so an automated capture run starts
/// on a populated Home instead of the onboarding flow.
///
/// Screenshot automation needs the app in a known, signed-in state. Driving the
/// onboarding UI to get there is slow and brittle — it is several screens of
/// focus-engine navigation whose layout changes whenever onboarding does, and it
/// would have to be re-taught for tvOS and iOS separately. Seeding the share
/// directly reuses the exact code path onboarding calls (`didConfigureNFSShare`),
/// so the resulting state is identical to a hand-added share.
///
/// DEBUG-only and inert unless the environment asks for it, so nothing here can
/// reach a shipped build or change a normal run.
///
/// Used by `tools/capture-shots.sh`:
/// ```
/// PLOZZ_SHOTS_NFS_HOST=192.168.68.71
/// PLOZZ_SHOTS_NFS_EXPORT=/mnt/user/Media
/// PLOZZ_SHOTS_NFS_NAME=Brandoland
/// ```
enum ScreenshotSeed {
    /// Applies the seed if the environment provides one and the app has no
    /// accounts yet. Idempotent: a second launch finds the share already there
    /// and leaves the scanned catalog alone, which is what keeps repeat capture
    /// runs fast.
    ///
    /// Adding the first account starts the one-time first-run chain (the profile
    /// confirm step, then the theme picker). A capture run wants Home, not
    /// onboarding, so both are completed here through the same calls their
    /// buttons make. Marking them done also stops them reappearing next launch.
    @MainActor
    static func applyIfRequested(to appState: AppState) {
        #if DEBUG
        // Start listening first: a repeat run finds the share already there and
        // returns below, but it still needs to be drivable.
        appState.screenshotDirector.startWatchingForRequests()

        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PLOZZ_SHOTS_NFS_HOST"],
              let export = environment["PLOZZ_SHOTS_NFS_EXPORT"],
              !host.isEmpty,
              !export.isEmpty
        else { return }

        guard appState.accountsProviders.accounts.isEmpty else { return }

        let port = environment["PLOZZ_SHOTS_NFS_PORT"].flatMap(Int.init)
        let name = environment["PLOZZ_SHOTS_NFS_NAME"] ?? ""

        appState.didConfigureNFSShare(
            host: host,
            port: port,
            exportPath: export,
            displayName: name
        )

        appState.confirmFirstRunProfile()
        appState.finishThemeSelection()
        #endif
    }

    /// Holds the player's transport bar open for a capture run.
    ///
    /// The transport is the part of the player worth photographing — title,
    /// scrubber, elapsed/remaining, and the Info/Cast/subtitle affordances —
    /// and it is also the part that is deliberately hard to catch: it appears
    /// on input and hides a few seconds later, and a run driven by files rather
    /// than by a remote never supplies that input. Every timing-based attempt to
    /// catch it produced either a black frame (still buffering) or bare video
    /// (already faded).
    ///
    /// So it is asked for directly. `controlsVisible` is re-asserted for a short
    /// while rather than set once, because the auto-hide countdown is armed when
    /// the playhead is confirmed advancing — which happens *after* the model is
    /// built, and would otherwise clear a flag set here before playback began.
    ///
    /// DEBUG-only, and only when the capture environment asked for a seeded run,
    /// so an ordinary session's controls behave exactly as they always have.
    @MainActor
    static func holdPlayerControlsIfRequested(_ viewModel: PlayerViewModel?) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_SHOTS_NFS_HOST"] != nil,
              environment["PLOZZ_SHOTS_HOLD_CONTROLS"] == "1",
              let viewModel
        else { return }

        Task { @MainActor in
            for _ in 0..<240 {
                viewModel.controls.controlsVisible = true
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
    }
}
