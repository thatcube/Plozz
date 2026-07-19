#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import FeatureAuthCore

/// Authentication coordinator shown once a server is selected.
///
/// Quick Connect is the primary, default path. A low-emphasis secondary action
/// lets users who prefer (or must, when Quick Connect is disabled) sign in with
/// a username and password. Both paths produce the same `UserSession`.
public struct AuthView: View {
    private let server: MediaServer
    private let deviceID: String
    private let onAuthenticated: (UserSession) -> Void
    private let onCancel: () -> Void

    @State private var showingPasswordSignIn = false

    public init(
        server: MediaServer,
        deviceID: String,
        onAuthenticated: @escaping (UserSession) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.server = server
        self.deviceID = deviceID
        self.onAuthenticated = onAuthenticated
        self.onCancel = onCancel
    }


    public var body: some View {
        if server.provider == .emby {
            PasswordSignInView(
                viewModel: PasswordSignInViewModel(
                    service: PasswordSignInService(server: server, deviceID: deviceID),
                    onAuthenticated: onAuthenticated
                ),
                serverName: server.name,
                providerName: server.provider.displayName,
                onBack: onCancel
            )
        } else {
            Group {
                if showingPasswordSignIn {
                    PasswordSignInView(
                        viewModel: PasswordSignInViewModel(
                            service: PasswordSignInService(server: server, deviceID: deviceID),
                            onAuthenticated: onAuthenticated
                        ),
                        serverName: server.name,
                        providerName: server.provider.displayName,
                        onBack: { showingPasswordSignIn = false }
                    )
                } else {
                    QuickConnectView(
                        viewModel: QuickConnectViewModel(
                            service: QuickConnectService(server: server, deviceID: deviceID),
                            onAuthenticated: onAuthenticated
                        ),
                        serverName: server.name,
                        onCancel: onCancel,
                        secondaryAction: .init(title: "Sign in with username & password") {
                            showingPasswordSignIn = true
                        }
                    )
                }
            }
        }
    }
}

#endif
