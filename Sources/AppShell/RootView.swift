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
                avatarURLString: request.homeUserAvatarURL,
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
/// Layout mirrors Plex's own tvOS PIN screen: the Home user's avatar (with a
/// small lock badge) and name at the top, an "PIN" pill that fills as digits
/// are entered, and a single horizontal strip of digit keys + delete below.
/// One axis of focus is what the Siri remote handles best.
private struct PlexPINEntryView: View {
    let appState: AppState
    let userName: String
    let avatarURLString: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin: String = ""

    private static let pinLength = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 36) {
                Spacer(minLength: 0)
                avatarBadge
                Text(userName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                pinField
                if let error = appState.plexPINError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
                    .padding(.horizontal, 60)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onChange(of: appState.plexPINError) { _, newValue in
                // Wrong-PIN response: clear the entered dots so the user can
                // retry without first backspacing four times.
                if newValue != nil { pin = "" }
            }
        }
    }

    /// Large circular Plex avatar with a small lock badge — matches Plex's
    /// tvOS PIN screen. Falls back to a person glyph when no thumb is cached.
    private var avatarBadge: some View {
        let url = avatarURLString.flatMap(URL.init(string:))
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.18))
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(Circle())

            // Small lock badge in the corner, à la Plex.
            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 2))
            .offset(x: 4, y: 4)
        }
    }

    /// "PIN" pill that fills with masked dots as digits are entered. Before
    /// any entry it reads "PIN"; while typing it shows • per digit so the
    /// user can see progress without revealing the code.
    private var pinField: some View {
        Group {
            if pin.isEmpty {
                Text("PIN")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(6)
            } else {
                Text(String(repeating: "•", count: pin.count))
                    .font(.system(size: 44, weight: .bold))
                    .tracking(10)
                    .monospacedDigit()
            }
        }
        .frame(minWidth: 220, minHeight: 64)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        )
    }

    private func appendDigit(_ d: String) {
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < Self.pinLength else { return }
        pin.append(d)
        if pin.count == Self.pinLength {
            // Auto-submit the moment the 4th digit lands. Snappy is the goal.
            onSubmit(pin)
        }
    }

    private func deleteDigit() {
        if !pin.isEmpty { pin.removeLast() }
    }
}

/// Single horizontal row of digit keys 0–9 plus a delete key — the layout
/// Plex itself uses on tvOS, and the one-axis path the Siri remote handles
/// best. Each key is a focusable Button so focus is always anchored and
/// Menu/Back can't fall through to the system.
private struct PINStrip: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let digits: [String] = ["1","2","3","4","5","6","7","8","9","0"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(digits, id: \.self) { d in
                digitKey(d)
            }
            deleteKey
        }
    }

    private func digitKey(_ digit: String) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(digit)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .frame(width: 78, height: 88)
        }
        .buttonStyle(.bordered)
    }

    private var deleteKey: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Image(systemName: "delete.left")
                .font(.title2)
                .frame(width: 92, height: 88)
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
