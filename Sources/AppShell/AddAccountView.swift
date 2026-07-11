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
                    FirstRunBranding()
                }

                ProviderChoiceGroup(onSelect: onSelect)
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

private struct FirstRunBranding: View {
    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 24) {
                Image("PlozzLogo")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 128, height: 128)

                Image("PlozzWordmark")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 224, height: 112)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plozz")

            Text("Free forever and open source.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 480)
    }
}

private struct ProviderChoiceGroup: View {
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProviderChoiceRow(
                provider: .jellyfin,
                title: "Jellyfin",
                height: 152
            ) {
                onSelect(.jellyfin)
            }

            Divider().padding(.horizontal, 24)

            ProviderChoiceRow(
                provider: .plex,
                title: "Plex",
                height: 152
            ) {
                onSelect(.plex)
            }

            Divider().padding(.horizontal, 24)

            ProviderChoiceRow(
                provider: .mediaShare,
                title: "SMB Share",
                height: 108
            ) {
                onSelect(.mediaShare)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 720)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .focusSection()
    }
}

private struct ProviderChoiceRow: View {
    let provider: ProviderKind
    let title: LocalizedStringKey
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                ProviderBrandMark(provider: provider, size: 64)

                Text(title)
                    .font(.system(size: 32, weight: .semibold))

                Spacer(minLength: 24)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 22, weight: .semibold))
                    .settingsRowSecondary()
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
    }
}

#endif
