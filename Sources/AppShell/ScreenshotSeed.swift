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

        // Installed before the "already seeded" bail-out below, because a repeat
        // run — the common case, since the scanned catalog is deliberately kept
        // — returns from that guard and would otherwise leave the router with no
        // way to change the subtitle mode per shot.
        setSubtitleMode = { [weak appState] mode in
            appState?.profileSettings.subtitleBehaviorModel.settings.subtitleMode = mode
        }

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

        // Subtitles on. A shot of the subtitle style editor with no caption
        // under it shows the controls and none of what they control, which is
        // the whole point of that screen — and whether a caption happens to be
        // burned in otherwise depends on whether the file's track is flagged
        // default, which varies per title.
        appState.profileSettings.subtitleBehaviorModel.settings.subtitleMode = .all
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
    /// Turns the profile's subtitle mode on or off for the shot about to be
    /// taken. Installed by the seed (which is the only thing holding the app
    /// state) and called by the capture router, which does not.
    ///
    /// Per-shot rather than once at launch because the two player shots want
    /// opposite things: the subtitle *style* editor is meaningless with nothing
    /// to style, while the transport-bar shot wants clean picture behind it
    /// instead of a line of dialogue crowding the title.
    @MainActor
    static var setSubtitleMode: ((SubtitleMode) -> Void)?

    /// Whether the *current* play request should pause once it has seeked.
    ///
    /// This is what makes a player shot reproducible. Playback keeps running
    /// while the rig waits for the picture to settle, so the frame that gets
    /// photographed is wherever the film happened to be by then — which moves
    /// with buffering and made every run produce a different, often unusable
    /// frame (a cut to black, a caption that had just expired). Paused, the shot
    /// is whatever is at `at` seconds, every time.
    @MainActor
    static var pausesPlayback = false

    /// The position a paused shot should hold on.
    @MainActor
    static var pendingPlayerSeek: TimeInterval?

    /// Waits for playback to genuinely be up, then parks it on an exact frame.
    ///
    /// The order matters and both halves were learned the hard way. Pausing on a
    /// timer paused whatever was on screen at that moment, and what was on
    /// screen was often still the bring-up spinner — so the shot came back with
    /// a loading message across the middle of it, permanently, because a paused
    /// player never finishes loading. And even once playing, the frame reached
    /// after a fixed wait moves with however long the file took to buffer, so
    /// two runs never produced the same picture.
    ///
    /// Waiting for `showBringUpSpinner` to clear fixes the first; seeking back to
    /// the requested position *after* it clears fixes the second.
    @MainActor
    private static func freeze(_ viewModel: PlayerViewModel, at target: TimeInterval?) async {
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !viewModel.showBringUpSpinner else { continue }
            // A cleared spinner means the first frame is up; give the engine a
            // beat to actually be playing before asking it to move.
            try? await Task.sleep(for: .seconds(2))
            break
        }
        if let target { await viewModel.seek(to: target) }
        // The seek re-arms the spinner briefly. Let it clear again, or the pause
        // lands back on a loading frame — the exact problem this exists to fix.
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            if !viewModel.showBringUpSpinner { break }
        }
        try? await Task.sleep(for: .milliseconds(750))
        if !viewModel.controls.isPaused { viewModel.togglePlayPause() }
    }

    @MainActor
    static func holdPlayerControlsIfRequested(_ viewModel: PlayerViewModel?) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_SHOTS_NFS_HOST"] != nil,
              environment["PLOZZ_SHOTS_HOLD_CONTROLS"] == "1",
              let viewModel
        else { return }


        if pausesPlayback {
            pausesPlayback = false
            let target = pendingPlayerSeek
            pendingPlayerSeek = nil
            Task { @MainActor in
                await freeze(viewModel, at: target)
            }
        }

        // The style editor pins the transport open on its own, so holding
        // `controlsVisible` on top of it would fight. Only one of the two runs.
        if PlayerScreenshotHook.pendingPanel != nil { return }

        Task { @MainActor in
            for _ in 0..<240 {
                viewModel.controls.controlsVisible = true
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
    }
}
