#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuth
import FeatureDiscovery

/// Entry point for adding an account, letting the user pick which backend to
/// connect: **Jellyfin** (existing server picker → Quick Connect) or **Plex**
/// (plex.tv PIN link). Selecting a provider pushes its own sign-in flow; both
/// ultimately hand back through `AppState` and join the multi-account list.
struct AddAccountView: View {
    let deviceID: String
    let canReturnToApp: Bool
    let signedInServers: [SignedInServer]
    let onJellyfinServerSelected: (MediaServer) -> Void
    let onPlexAuthenticated: (UserSession) -> Void
    let onPlexAuthenticatedMany: ([UserSession]) -> Void
    let onShareConfigured: (ShareDraft) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: ProviderKind?
    @State private var navigationDirection: NavigationDirection = .forward

    private enum NavigationDirection {
        case forward
        case backward
    }

    init(
        deviceID: String,
        canReturnToApp: Bool,
        initialProvider: ProviderKind? = nil,
        signedInServers: [SignedInServer] = [],
        onJellyfinServerSelected: @escaping (MediaServer) -> Void,
        onPlexAuthenticated: @escaping (UserSession) -> Void,
        onPlexAuthenticatedMany: @escaping ([UserSession]) -> Void = { _ in },
        onShareConfigured: @escaping (ShareDraft) -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        self.deviceID = deviceID
        self.canReturnToApp = canReturnToApp
        self.signedInServers = signedInServers
        self.onJellyfinServerSelected = onJellyfinServerSelected
        self.onPlexAuthenticated = onPlexAuthenticated
        self.onPlexAuthenticatedMany = onPlexAuthenticatedMany
        self.onShareConfigured = onShareConfigured
        self.onCancel = onCancel
        // Seed the flow's starting screen. Cancelling Quick Connect returns here
        // with the provider preserved so we land on its server list, not the
        // chooser. Plex has no intermediate list, so it falls back to the chooser.
        _choice = State(initialValue: initialProvider == .jellyfin ? initialProvider : nil)
    }

    var body: some View {
        ZStack {
            switch choice {
            case .none:
                chooser
                    .transition(pageTransition)
            case .jellyfin:
                ServerPickerView(
                    signedInServers: signedInServers.filter { $0.server.provider == .jellyfin },
                    onBack: navigateBackToChooser
                ) { onJellyfinServerSelected($0) }
                    .transition(pageTransition)
            case .plex:
                PlexLinkView(
                    viewModel: PlexAuthViewModel(
                        service: PlexAuthService(deviceID: deviceID),
                        onAuthenticated: onPlexAuthenticated,
                        onAuthenticatedMany: onPlexAuthenticatedMany
                    ),
                    onCancel: navigateBackToChooser
                )
                .transition(pageTransition)
            case .mediaShare:
                AddShareView(
                    onBack: navigateBackToChooser,
                    onConfigured: onShareConfigured
                )
                .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var chooser: some View {
        VStack(spacing: 40) {
            if !canReturnToApp {
                FirstRunBrandMark()
            }

            HStack(spacing: 32) {
                providerButton(
                    provider: .jellyfin,
                    detail: "Find it on your network or enter an address."
                ) { navigate(to: .jellyfin) }

                providerButton(
                    provider: .plex,
                    detail: "Link this device at plex.tv/link."
                ) { navigate(to: .plex) }
            }

            // Media shares are deliberately second-class: a smaller secondary
            // button under the two first-class backends, not a co-equal card.
            // Kept side-by-side with Cancel rather than stacked.
            HStack(spacing: 24) {
                Button {
                    navigate(to: .mediaShare)
                } label: {
                    Label("Add a local media share (SMB)", systemImage: "externaldrive.connected.to.line.below.fill")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                if canReturnToApp {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Menu/back should return to wherever the flow was opened from (e.g.
        // Settings), not fall through and suspend the whole app.
        .onExitCommand {
            if canReturnToApp { onCancel() }
        }
    }

    private func providerButton(
        provider: ProviderKind,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ProviderBrandMark(provider: provider, size: 100)
                Text(provider.displayName)
                    .font(.title2).bold()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(width: 420, height: 400)
        }
        // Same focus treatment as the Settings About / Report a Problem cards:
        // accent outline + gentle lift, no contrast inversion.
        .buttonStyle(SettingsCardButtonStyle())
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let enteringOffset: CGFloat = navigationDirection == .forward ? 72 : -72
        let leavingOffset: CGFloat = navigationDirection == .forward ? -48 : 48
        return .asymmetric(
            insertion: .offset(x: enteringOffset).combined(with: .opacity),
            removal: .offset(x: leavingOffset).combined(with: .opacity)
        )
    }

    private var pageAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.9)
    }

    private func navigate(to destination: ProviderKind) {
        withAnimation(pageAnimation) {
            navigationDirection = .forward
            choice = destination
        }
    }

    private func navigateBackToChooser() {
        withAnimation(pageAnimation) {
            navigationDirection = .backward
            choice = nil
        }
    }
}

private struct FirstRunBrandMark: View {
    var body: some View {
        Image("PlozzLogo")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
    }
}

#endif
