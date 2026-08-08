import Foundation

/// A panel the screenshot rig wants the player to open once it is up.
///
/// The panel and its sub-screen are `@State` inside `PlayerControls`, which is
/// right — nothing outside the controls layer should be steering them — so this
/// is the one narrow exception. It exists because the subtitle style editor is
/// worth photographing and there is no way to reach it without pressing the
/// remote, which is the machinery the capture rig exists to avoid.
///
/// Deliberately NOT a property on ``PlayerControlsModel``. That type's tracked
/// property count is held under a decreasing-only budget by the architecture
/// guard, and spending one of those on a debug hook would be paying a permanent
/// cost for a temporary convenience. A plain static also cannot invalidate
/// anything, which is the honest description of what this needs to be: the
/// value is set before the player is built, so the controls read it once on
/// appear rather than observing it.
///
/// Lives in `FeaturePlayback` rather than beside the rest of the rig in
/// `AppShell` so the dependency points the way it already does — the shell
/// knows about the player, not the other way round.
public enum PlayerScreenshotHook {
    public enum Panel: String, Sendable {
        /// The Subtitles panel's Style editor, over live playback.
        case subtitleStyle
    }

    /// Set by the capture rig when it starts playback; consumed by the controls.
    /// Always `nil` outside a capture run, and never written in release.
    @MainActor
    public static var pendingPanel: Panel?
}
