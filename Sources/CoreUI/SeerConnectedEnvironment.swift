#if canImport(SwiftUI)
import SwiftUI

/// Whether Seerr/Jellyseerr is connected for the active profile, injected at the
/// app root (`RootView` / `PlozziOSRootView`) alongside `\.plozzCardStyle` and
/// `\.plozzWatchStatusIndicator`.
///
/// Lives in the environment rather than being threaded through view parameters
/// because the one thing that reads it — the corner mark on a card whose title
/// isn't in your library — is drawn deep inside `MediaCardPlaybackIndicators`,
/// under every row, grid and shelf in the app. Passing a `Bool` down all of those
/// would touch dozens of call sites to answer a question none of them ask.
///
/// Defaults to `false`, which is both the safe answer and the common one: most
/// people never install Seerr, and with it absent an unowned title is still
/// marked — just as information rather than an invitation.
private struct PlozzSeerConnectedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var plozzSeerConnected: Bool {
        get { self[PlozzSeerConnectedKey.self] }
        set { self[PlozzSeerConnectedKey.self] = newValue }
    }
}
#endif
