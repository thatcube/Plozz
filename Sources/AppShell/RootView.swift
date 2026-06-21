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

            case let .onboarding(.selectingServer, canReturnToApp):
                AddAccountView(
                    deviceID: appState.deviceID,
                    canReturnToApp: canReturnToApp,
                    onJellyfinServerSelected: { server in appState.selectServer(server) },
                    onPlexAuthenticated: { session in appState.didAuthenticatePlex(session) },
                    onCancel: { appState.cancelAuthentication() }
                )

            case let .onboarding(.authenticating(server), _):
                AuthView(
                    server: server,
                    deviceID: appState.deviceID,
                    onAuthenticated: { session in appState.didAuthenticate(session) },
                    onCancel: { appState.cancelAuthentication() }
                )

            case .ready:
                if let provider = appState.primaryProvider {
                    MainTabView(
                        provider: provider,
                        captionModel: appState.captionModel,
                        spoilerModel: appState.spoilerModel,
                        ratingsProvider: appState.ratingsProvider,
                        accounts: appState.accounts,
                        activeAccountID: appState.primaryActiveAccount?.id,
                        pendingPlayItemID: Binding(
                            get: { appState.pendingPlayItemID },
                            set: { appState.pendingPlayItemID = $0 }
                        ),
                        onAddAccount: { appState.addAccount() },
                        onRemoveAccount: { appState.removeAccount(id: $0.id) },
                        onSignOutAll: { appState.signOutAll() }
                    )
                }

            case let .failed(error, _):
                FailureView(message: error.userMessage) {
                    appState.retry()
                }
            }
        }
        .onAppear { if case .launching = appState.state { appState.bootstrap() } }
        .onOpenURL { appState.handle(url: $0) }
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
