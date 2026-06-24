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
        // Read the PIN request HERE so the @Observable system registers it
        // as a dependency of body. The sheet's Binding closures aren't
        // tracked, so without this body never re-evaluates when the request
        // clears and the sheet stays up after a successful PIN.
        let pinRequest = appState.pendingPlexPINRequest
        return Group {
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
                        onSwitchProfile: { appState.requestProfileSelection() },
                        plexHomeUsersFetcher: { await appState.plexHomeUsers(forAccountID: $0) },
                        onSelectPlexHomeUser: { appState.setPlexHomeUserForActiveProfile(accountID: $0, user: $1) }
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
            get: { pinRequest },
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
///
/// tvOS lacks a numeric keyboard (`.keyboardType(.numberPad)` is ignored), so
/// a SecureField forces the full QWERTY remote keyboard for a 4-digit code.
/// This view uses a custom on-screen numeric pad instead — focus-friendly on
/// the Siri remote and the standard tvOS pattern for short numeric input.
private struct PlexPINEntryView: View {
    let appState: AppState
    let userName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""

    private static let pinLength = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Enter PIN for \(userName)")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                pinDots
                if let error = appState.plexPINError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                PINPad(onDigit: appendDigit, onDelete: deleteDigit)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onChange(of: appState.plexPINError) { _, newValue in
                // Wrong-PIN response: clear the dots so the user can retry
                // without first having to backspace four times.
                if newValue != nil { pin = "" }
            }
        }
    }

    private var pinDots: some View {
        HStack(spacing: 20) {
            ForEach(0..<Self.pinLength, id: \.self) { i in
                Circle()
                    .stroke(Color.primary.opacity(0.35), lineWidth: 2)
                    .background(
                        Circle().fill(i < pin.count ? Color.primary : Color.clear)
                    )
                    .frame(width: 24, height: 24)
            }
        }
    }

    private func appendDigit(_ d: String) {
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < Self.pinLength else { return }
        pin.append(d)
        if pin.count == Self.pinLength {
            // Auto-submit when the 4th digit is entered. Snappy is the goal.
            onSubmit(pin)
        }
    }

    private func deleteDigit() {
        if !pin.isEmpty { pin.removeLast() }
    }
}

/// Focus-friendly numeric pad for tvOS: rows [1 2 3][4 5 6][7 8 9][ _ 0 ⌫ ].
/// Each button is a focusable Button so the Siri remote can navigate the grid
/// and focus is always anchored — Menu/Back can't fall through to the system.
private struct PINPad: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            row(["1", "2", "3"])
            row(["4", "5", "6"])
            row(["7", "8", "9"])
            HStack(spacing: 16) {
                Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                digitButton("0")
                deleteButton
            }
        }
    }

    private func row(_ digits: [String]) -> some View {
        HStack(spacing: 16) {
            ForEach(digits, id: \.self) { d in
                digitButton(d)
            }
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(digit)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.bordered)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Image(systemName: "delete.left")
                .font(.title)
                .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Delete")
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
