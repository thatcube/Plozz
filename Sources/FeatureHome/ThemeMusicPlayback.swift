#if canImport(SwiftUI) && canImport(AVFoundation)
import CoreModels
import CoreNetworking
import SwiftUI

private struct ThemeMusicControllerKey: EnvironmentKey {
    static let defaultValue: ThemeMusicController? = nil
}

private struct ThemeMusicSettingsKey: EnvironmentKey {
    static let defaultValue = ThemeMusicSettings.default
}

private struct ThemeMusicAuthenticatedHTTPResolverKey: EnvironmentKey {
    static let defaultValue: (any AuthenticatedHTTPResourceResolving)? = nil
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

    var themeMusicAuthenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    {
        get { self[ThemeMusicAuthenticatedHTTPResolverKey.self] }
        set { self[ThemeMusicAuthenticatedHTTPResolverKey.self] = newValue }
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
    @Environment(\.themeMusicAuthenticatedHTTPResolver) private var authenticatedHTTPResolver
    @State private var resolutionGeneration: UInt64 = 0

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
                resolutionGeneration &+= 1
                let generation = resolutionGeneration
                guard let controller else { return }
                guard let playbackID else {
                    controller.stop()
                    return
                }
                if controller.currentPlaybackID != playbackID {
                    controller.stop()
                }
                guard settings.shouldPlay, !controller.isBlocked else {
                    controller.stop(ifPlaying: playbackID)
                    return
                }
                guard let theme = await resolve(),
                      !Task.isCancelled,
                      generation == resolutionGeneration else {
                    return
                }
                do {
                    let resolvedURL = try await resolveThemeMusicURL(
                        theme,
                        authenticatedHTTPResolver: authenticatedHTTPResolver
                    )
                    guard !Task.isCancelled,
                          generation == resolutionGeneration,
                          !controller.isBlocked else {
                        return
                    }
                    controller.play(
                        theme,
                        resolvedURL: resolvedURL,
                        playbackID: playbackID,
                        settings: settings
                    )
                } catch {
                    guard !Task.isCancelled,
                          generation == resolutionGeneration else {
                        return
                    }
                    controller.stop(ifPlaying: playbackID)
                    PlozzLog.app.error(
                        "Theme music: source resolution failed item=\(theme.itemID) error=\(String(describing: error))"
                    )
                }
            }
            .onDisappear {
                resolutionGeneration &+= 1
                guard let playbackID else { return }
                controller?.stop(ifPlaying: playbackID)
            }
    }
}

enum ThemeMusicSourceResolutionError: Error, Equatable {
    case missingAuthenticatedResolver
    case unsupportedSource
}

@MainActor
func resolveThemeMusicURL(
    _ theme: ThemeMusic,
    authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
) async throws -> URL {
    switch theme.playbackSource {
    case .publicURL(let source):
        return source.url
    case .authenticatedHTTP(let locator):
        guard let authenticatedHTTPResolver else {
            throw ThemeMusicSourceResolutionError.missingAuthenticatedResolver
        }
        return try await authenticatedHTTPResolver.resolve(locator)
    case .networkFile, .dlnaResource:
        throw ThemeMusicSourceResolutionError.unsupportedSource
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
