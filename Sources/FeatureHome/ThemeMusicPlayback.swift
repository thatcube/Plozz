#if canImport(SwiftUI) && canImport(AVFoundation)
import CoreModels
import SwiftUI

private struct ThemeMusicControllerKey: EnvironmentKey {
    static let defaultValue: ThemeMusicController? = nil
}

private struct ThemeMusicSettingsKey: EnvironmentKey {
    static let defaultValue = ThemeMusicSettings.default
}

public extension EnvironmentValues {
    var themeMusicController: ThemeMusicController? {
        get { self[ThemeMusicControllerKey.self] }
        set { self[ThemeMusicControllerKey.self] = newValue }
    }

    var themeMusicSettings: ThemeMusicSettings {
        get { self[ThemeMusicSettingsKey.self] }
        set { self[ThemeMusicSettingsKey.self] = newValue }
    }
}

private struct ThemeMusicPlaybackTaskID: Equatable {
    let playbackID: String?
    let settings: ThemeMusicSettings
    let isBlocked: Bool
}

private struct ThemeMusicPlaybackModifier: ViewModifier {
    let playbackID: String?
    let resolve: () async -> ThemeMusic?

    @Environment(\.themeMusicController) private var controller
    @Environment(\.themeMusicSettings) private var settings

    private var taskID: ThemeMusicPlaybackTaskID {
        ThemeMusicPlaybackTaskID(
            playbackID: playbackID,
            settings: settings,
            isBlocked: controller?.isBlocked ?? true
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: taskID) {
                guard let playbackID, let controller else { return }
                guard settings.shouldPlay, !controller.isBlocked else {
                    controller.stop(ifPlaying: playbackID)
                    return
                }
                guard let theme = await resolve(),
                      !Task.isCancelled,
                      !controller.isBlocked else { return }
                controller.play(theme, playbackID: playbackID, settings: settings)
            }
            .onDisappear {
                guard let playbackID else { return }
                controller?.stop(ifPlaying: playbackID)
            }
    }
}

extension View {
    func themeMusicPlayback(
        playbackID: String?,
        resolve: @escaping () async -> ThemeMusic?
    ) -> some View {
        modifier(
            ThemeMusicPlaybackModifier(
                playbackID: playbackID,
                resolve: resolve
            )
        )
    }
}
#endif
