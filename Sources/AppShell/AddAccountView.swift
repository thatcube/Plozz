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
        ProviderChooserView(
            showsBranding: !canReturnToApp,
            showsBackButton: canReturnToApp,
            onBack: onCancel,
            onSelect: navigate(to:)
        )
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

private struct ProviderChooserView: View {
    let showsBranding: Bool
    let showsBackButton: Bool
    let onBack: () -> Void
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 72) {
                if showsBranding {
                    FirstRunBrandPanel()
                }

                ProviderChoiceColumn(onSelect: onSelect)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsBackButton {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if showsBackButton { onBack() }
        }
    }
}

private struct FirstRunBrandPanel: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            Image("PlozzLogo")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
        }
        .frame(width: 460, height: 680)
    }
}

private struct ProviderChoiceColumn: View {
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        VStack(spacing: 28) {
            ProviderChoiceCard(
                provider: .jellyfin,
                title: "Jellyfin",
                detail: "Find it on your network or enter an address.",
                height: 220,
                markSize: 88
            ) {
                onSelect(.jellyfin)
            }

            ProviderChoiceCard(
                provider: .plex,
                title: "Plex",
                detail: "Link this device at plex.tv/link.",
                height: 220,
                markSize: 88
            ) {
                onSelect(.plex)
            }

            ProviderChoiceCard(
                provider: .mediaShare,
                title: "Media Share (SMB)",
                detail: "Connect to a shared folder on your local network.",
                height: 128,
                markSize: 60
            ) {
                onSelect(.mediaShare)
            }
        }
        .frame(width: 760)
    }
}

private struct ProviderChoiceCard: View {
    let provider: ProviderKind
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let height: CGFloat
    let markSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 28) {
                ProviderBrandMark(provider: provider, size: markSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 24)

                Image(systemName: "chevron.forward")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsCardButtonStyle())
    }
}

#endif
