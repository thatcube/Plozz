#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuth
import FeatureDiscovery

/// Top-level view that renders one screen per `SessionState`.
public struct RootView: View {
    @State private var appState: AppState

    @MainActor
    public init(appState: AppState? = nil) {
        _appState = State(initialValue: appState ?? AppState())
    }

    public var body: some View {
        Group {
            switch appState.state {
            case .launching:
                LaunchView()

            case .selectingServer:
                ServerPickerView { server in
                    appState.selectServer(server)
                }

            case let .authenticating(server):
                AuthView(
                    server: server,
                    deviceID: appState.deviceID,
                    onAuthenticated: { session in appState.didAuthenticate(session) },
                    onCancel: { appState.cancelAuthentication() }
                )

            case .authenticated:
                if let provider = appState.provider {
                    MainTabView(provider: provider, captionModel: appState.captionModel) {
                        appState.signOut()
                    }
                }

            case let .failed(error):
                FailureView(message: error.userMessage) {
                    appState.retry()
                }
            }
        }
        .onAppear { if case .launching = appState.state { appState.bootstrap() } }
    }
}

/// Brief splash while we check for a stored session.
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Plozz")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
