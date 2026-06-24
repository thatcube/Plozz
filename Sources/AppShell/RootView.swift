#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuth
import FeatureDiscovery

/// Top-level view that renders one screen per `SessionState`.
public struct RootView: View {
    @State private var appState: AppState
    @Environment(\.colorScheme) private var systemColorScheme

    @MainActor
    public init(appState: AppState? = nil) {
        _appState = State(initialValue: appState ?? AppState())
    }

    /// The palette for the currently-selected theme, re-resolved when either the
    /// chosen `AppTheme` or the device colour scheme changes.
    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(for: appState.themeModel.theme, systemColorScheme: systemColorScheme)
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
                if appState.isChoosingProfile {
                    ProfileSelectionView(appState: appState, canCancel: appState.primaryProvider != nil)
                } else {
                    let accounts = appState.homeAccounts
                    if !accounts.isEmpty {
                    MainTabView(
                        accounts: accounts,
                        captionModel: appState.captionModel,
                        spoilerModel: appState.spoilerModel,
                        themeModel: appState.themeModel,
                        diagnosticsModel: appState.diagnosticsModel,
                        homeVisibility: appState.homeLibraryVisibilityModel,
                        ratingsProvider: appState.ratingsProvider,
                        trakt: appState.traktService,
                        mediaItemActionHandler: appState.mediaItemActionHandler,
                        displayAccounts: appState.accounts,
                        activeAccountID: appState.primaryActiveAccount?.id,
                        profiles: appState.profilesModel.profiles,
                        activeProfile: appState.profilesModel.activeProfile,
                        askProfileOnStartup: appState.profilesModel.askProfileOnStartup,
                        profilesEnabled: appState.profilesModel.profilesEnabled,
                        pendingPlayItemID: Binding(
                            get: { appState.pendingPlayItemID },
                            set: { appState.pendingPlayItemID = $0 }
                        ),
                        isAccountIncludedInActiveProfile: { appState.isAccountIncludedInActiveProfile($0) },
                        onSetAccountIncluded: { appState.setAccount($0, includedInActiveProfile: $1) },
                        onSetAskProfileOnStartup: { appState.setAskProfileOnStartup($0) },
                        onEnableProfiles: { appState.enableProfiles() },
                        onDisableProfiles: { appState.disableProfiles() },
                        onSaveProfile: { appState.saveProfile($0) },
                        onDeleteProfile: { appState.removeProfile(id: $0) },
                        onAddAccount: { appState.addAccount() },
                        onRemoveAccount: { appState.removeAccount(id: $0.id) },
                        onSignOutAll: { appState.signOutAll() },
                        onSwitchProfile: { appState.requestProfileSelection() }
                    )
                    .id("\(appState.profilesModel.activeProfileID)#\(appState.plexIdentityGeneration)")
                    }
                }

            case let .failed(error, _):
                FailureView(message: error.userMessage) {
                    appState.retry()
                }
            }
        }
        .background { AppBackground(palette: resolvedPalette) }
        .environment(\.themePalette, resolvedPalette)
        .preferredColorScheme(appState.themeModel.theme.preferredColorScheme)
        .sheet(item: Binding(
            get: { appState.pendingPlexPINRequest },
            set: { newValue in if newValue == nil { appState.dismissPlexPINIfPresented() } }
        )) { request in
            PlexPINEntryView(
                appState: appState,
                userName: request.homeUserName,
                onSubmit: { appState.submitPlexPIN($0) },
                onCancel: { appState.cancelPlexPIN() }
            )
        }
        .onAppear { if case .launching = appState.state { appState.bootstrap() } }
        .onOpenURL { appState.handle(url: $0) }
    }
}

/// Modal PIN entry shown when switching to a profile mapped to a PIN-protected
/// Plex Home user. The PIN is passed straight to Plex and never stored.
private struct PlexPINEntryView: View {
    let appState: AppState
    let userName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)
                Text("Enter PIN for \(userName)")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                SecureField("PIN", text: $pin)
                    .textContentType(.password)
                    .frame(maxWidth: 420)
                if let error = appState.plexPINError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("Continue") { onSubmit(pin) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
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
