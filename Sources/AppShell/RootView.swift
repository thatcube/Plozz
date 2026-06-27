#if canImport(SwiftUI)
import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
import FeatureDiscovery
import FeatureHome
import FeaturePlayback

/// Top-level view that renders one screen per `SessionState`.
public struct RootView: View {
    @State private var appState: AppState
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// The OS-level Reduce Transparency setting, OR-combined with the in-app
    /// "Reduce transparency" toggle (Settings ▸ Appearance) and injected as the
    /// app-wide `\.plozzReduceTransparency` so the liquid-glass surfaces switch
    /// to solid when *either* is on (the app override never weakens the OS one).
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    /// Deliberately an APP-WIDE (global) setting: a plain `@AppStorage` key with no
    /// profile namespace, so it persists across every profile and is intentionally
    /// NOT part of `AppState.rebuildSettingsModels()` (the per-profile store set).
    /// Do not scope this per profile — accessibility/visual-comfort preferences
    /// belong to the household, not an individual profile. See AGENTS.local.md
    /// ("Per-profile vs app-wide settings").
    @AppStorage("reduceTransparencyOverride") private var reduceTransparencyOverride = false
    /// Window-level black veil that survives the player's dismiss into Home so it
    /// can cover the TV's *physical* HDR/DV → SDR panel switch (which on some TVs
    /// lags ~1s behind tvOS's `displayDidSettle`). Injected into the environment so
    /// `PlayerView` can `engage()` it on exit; rendered as the topmost overlay here.
    @State private var displayVeil = DisplayVeilModel()

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
                ZStack {
                if appState.isChoosingProfile {
                    ProfileSelectionView(appState: appState, canCancel: appState.isProfileSelectionCancelable)
                        .transition(.opacity)
                } else {
                    let accounts = appState.homeAccounts
                    if !accounts.isEmpty {
                    MainTabView(
                        accounts: accounts,
                        captionModel: appState.captionModel,
                        spoilerModel: appState.spoilerModel,
                        playbackModel: appState.playbackModel,
                        themeModel: appState.themeModel,
                        diagnosticsModel: appState.diagnosticsModel,
                        musicPlayerModel: appState.musicPlayerModel,
                        audioController: appState.audioController,
                        homeVisibility: appState.homeLibraryVisibilityModel,
                        homeLayoutStore: HomeLayoutStore(namespace: appState.profilesModel.activeNamespace),
                        ratingsProvider: appState.ratingsProvider,
                        trakt: appState.traktService,
                        mediaItemActionHandler: appState.mediaItemActionHandler,
                        enqueueWatchMutation: { appState.enqueueWatchMutation($0) },
                        watchBridge: WatchOutboxBridge(
                            beginLiveSession: { accountID, itemID in
                                appState.beginLiveWatchSession(accountID: accountID, itemID: itemID)
                            },
                            finishPlayback: { accountID, itemID, mutation in
                                appState.finishLiveWatchSession(accountID: accountID, itemID: itemID, mutation: mutation)
                            }
                        ),
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
                        onSelectPlexHomeUser: { appState.setPlexHomeUserForActiveProfile(accountID: $0, user: $1) },
                        identitySources: appState.identitySourcesProvider,
                        onWarmIdentityIndex: { appState.warmIdentityIndex() }
                    )
                    .id("\(appState.profilesModel.activeProfileID)#\(appState.plexIdentityGeneration)")
                    .transition(.opacity)
                    }
                }
                }
                .animation(.easeInOut(duration: 0.5), value: appState.isChoosingProfile)

            case let .failed(error, _):
                FailureView(message: error.userMessage) {
                    appState.retry()
                }
            }
        }
        .background { AppBackground(palette: resolvedPalette) }
        .environment(\.themePalette, resolvedPalette)
        .environment(\.plozzReduceTransparency, systemReduceTransparency || reduceTransparencyOverride)
        .environment(displayVeil)
        .preferredColorScheme(appState.themeModel.theme.preferredColorScheme)
        .fullScreenCover(item: Binding(
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
        .onAppear {
            if case .launching = appState.state { appState.bootstrap() }
            appState.drainWatchOutbox()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { appState.drainWatchOutbox() }
        }
        .onOpenURL { appState.handle(url: $0) }
        // Window-level HDR/DV exit veil: a black layer above Home that the player
        // raises (via the injected `DisplayVeilModel`) just before it dismisses, so
        // black survives the dismiss and keeps covering the screen through the TV's
        // slow physical panel switch. Always returns to 0 (settle+buffer, no-settle
        // fallback, or the safety cap), so it can never strand the user on black.
        .overlay {
            Color.black
                .opacity(displayVeil.veilOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(displayVeil.veilOpacity > 0.01)
                // Snap to black *instantly* on engage (rising edge → no animation)
                // so the player's dismiss lands on an already-opaque window veil and
                // Home never shows through. Only the fade-OUT (falling edge, after
                // the panel settles) is animated.
                .animation(displayVeil.veilOpacity == 0 ? .easeInOut(duration: 0.4) : nil,
                           value: displayVeil.veilOpacity)
        }
        .modifier(RootDisplaySettleObserver { displayVeil.displayDidSettle() })
    }
}

/// Observes the tvOS display manager at the app root and forwards mode-switch-end
/// to the window-level `DisplayVeilModel`, so the exit veil can time its hold off
/// the *reported* settle even after the player has been dismissed. A no-op on
/// platforms without `AVDisplayManager` (e.g. macOS).
private struct RootDisplaySettleObserver: ViewModifier {
    let onSettle: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onReceive(
            NotificationCenter.default.publisher(for: .AVDisplayManagerModeSwitchEnd)
        ) { _ in
            onSettle()
        }
        #else
        content
        #endif
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

    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var isSubmitting: Bool = false

    private static let pinLength = 4

    var body: some View {
        // Track the request directly so a successful switch (which clears
        // pendingPlexPINRequest on AppState) re-evaluates THIS view and
        // triggers the onChange-based dismiss below. Belt-and-suspenders
        // dismissal that does NOT rely on the outer cover binding tracking
        // anything — call dismiss() ourselves from inside the cover.
        let pendingRequest = appState.pendingPlexPINRequest
        return ZStack {
            // Full-bleed dimmed backdrop so the PIN screen reads as a modal
            // OVER the app (like Plex does), not as an opaque context switch.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer(minLength: 0)
                avatarBadge
                Text(userName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    pinBoxes
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                // Reserve the error slot so the strip doesn't jump up/down
                // when an error appears/clears between attempts.
                Text(appState.plexPINError ?? " ")
                    .font(.callout)
                    .foregroundStyle(appState.plexPINError == nil ? Color.clear : .red)
                    .multilineTextAlignment(.center)
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.5 : 1.0)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onCancel)
        .onChange(of: appState.plexPINError) { _, newValue in
            // Wrong-PIN response: clear the entered boxes + drop the submitting
            // state so the user can retry without first backspacing four times.
            if newValue != nil {
                pin = ""
                isSubmitting = false
            }
        }
        .onChange(of: pendingRequest?.id) { _, newValue in
            // The cover's outer Binding tracking has been flaky on tvOS — call
            // dismiss() directly from inside the cover when AppState clears
            // the pending request (success path). This is the authoritative
            // signal that the PIN was accepted.
            if newValue == nil {
                PlozzLog.auth.debug("pendingPlexPINRequest cleared — calling dismiss()")
                dismiss()
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

    /// Four large rounded boxes that fill as digits land. Each is dark/outline
    /// when empty and solid+dot when filled. The next-to-fill box gets a thin
    /// highlight so the user can see entry progress without any focus on the
    /// boxes themselves (the strip below owns focus).
    private var pinBoxes: some View {
        HStack(spacing: 18) {
            ForEach(0..<Self.pinLength, id: \.self) { idx in
                let filled = idx < pin.count
                let next = !filled && idx == pin.count
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(filled ? Color.white.opacity(0.95) : Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            next ? Color.white.opacity(0.85) : Color.white.opacity(filled ? 0 : 0.25),
                            lineWidth: next ? 3 : 2
                        )
                    if filled {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 72, height: 84)
            }
        }
    }

    private func appendDigit(_ d: String) {
        guard !isSubmitting else { return }
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < Self.pinLength else { return }
        pin.append(d)
        if pin.count == Self.pinLength {
            // Auto-submit the moment the 4th digit lands. Snappy is the goal.
            // Flip isSubmitting so the user sees a spinner instead of "four
            // dots and nothing happens" while the network round-trip runs.
            PlozzLog.auth.debug("PIN auto-submit at 4 digits")
            isSubmitting = true
            onSubmit(pin)
        }
    }

    private func deleteDigit() {
        guard !isSubmitting else { return }
        if !pin.isEmpty { pin.removeLast() }
    }
}

/// Single horizontal row of digit keys 0–9 plus a delete key — the layout
/// Plex itself uses on tvOS, and the one-axis path the Siri remote handles
/// best. Each key is a focusable Button so focus is always anchored and
/// Menu/Back can't fall through to the system.
///
/// Compact, FIXED-size keys (no tile-to-fill). With 11 keys at 84pt + 10×16
/// spacing the strip is ~1080pt and centers naturally on a 1920pt tvOS
/// screen, leaving ~400pt clearance per side — zero clipping, and plenty
/// of room for the focused-key scale lift.
private struct PINStrip: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let digits: [String] = ["1","2","3","4","5","6","7","8","9","0"]
    private let digitKeyWidth: CGFloat = 84
    private let deleteKeyWidth: CGFloat = 104
    private let keyHeight: CGFloat = 100

    var body: some View {
        HStack(spacing: 16) {
            ForEach(digits, id: \.self) { d in
                Button {
                    onDigit(d)
                } label: {
                    Text(d)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                }
                .buttonStyle(PINKeyStyle(width: digitKeyWidth, height: keyHeight, isDestructive: false))
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 28, weight: .semibold))
            }
            .buttonStyle(PINKeyStyle(width: deleteKeyWidth, height: keyHeight, isDestructive: true))
            .accessibilityLabel("Delete")
        }
        // Vertical slack so the focus lift has clearance without bumping
        // neighbors in the column.
        .padding(.vertical, 12)
    }
}

/// Fixed-size, focus-friendly key button. Drawn entirely by this style so
/// the key's rendered frame is exactly width×height — no auto-expanding
/// fill from a bordered/prominent style and no inheritance from the parent
/// layout. Focused state lifts (scale 1.08) and brightens (white fill,
/// black foreground), with a soft drop shadow for depth.
private struct PINKeyStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(
            configuration: configuration,
            width: width,
            height: height,
            isDestructive: isDestructive
        )
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let width: CGFloat
    let height: CGFloat
    let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.18))
            )
            .foregroundStyle(
                isFocused
                ? (isDestructive ? Color.red : Color.black)
                : Color.primary
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.38 : 0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
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
