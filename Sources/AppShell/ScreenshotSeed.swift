import CoreModels
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
}
