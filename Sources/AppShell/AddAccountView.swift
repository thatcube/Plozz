#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuth
import FeatureDiscovery
import FeatureDiscoveryCore

/// Entry point for adding an account, letting the user pick which backend to
/// connect: **Jellyfin**, **Emby**, **Plex**, or a direct media share.
/// (plex.tv PIN link). Selecting a provider pushes its own sign-in flow; both
/// ultimately hand back through `AppState` and join the multi-account list.
struct AddAccountView: View {
    let deviceID: String
    let canReturnToApp: Bool
    let signedInServers: [SignedInServer]
    let onMediaBrowserServerSelected: (MediaServer) -> Void
    let onPlexAuthenticated: (UserSession) -> Void
    let onPlexAuthenticatedMany: ([UserSession]) -> Void
    let onShareConfigured: (ShareDraft) -> Void
    let onWebDAVShareConfigured: (WebDAVShareConfiguration) -> Void
    let onMediaShareConfigured: (MediaShareOnboardingResult) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: ProviderKind?
    @State private var plexAuthViewModel: PlexAuthViewModel
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var pageIsReady = true
    @State private var isTransitioning = false
    @State private var isPreparingPlex = false

    init(
        deviceID: String,
        canReturnToApp: Bool,
        initialProvider: ProviderKind? = nil,
        signedInServers: [SignedInServer] = [],
        onMediaBrowserServerSelected: @escaping (MediaServer) -> Void,
        onPlexAuthenticated: @escaping (UserSession) -> Void,
        onPlexAuthenticatedMany: @escaping ([UserSession]) -> Void = { _ in },
        onShareConfigured: @escaping (ShareDraft) -> Void = { _ in },
        onWebDAVShareConfigured: @escaping (WebDAVShareConfiguration) -> Void = { _ in },
        onMediaShareConfigured: @escaping (MediaShareOnboardingResult) -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        self.deviceID = deviceID
        self.canReturnToApp = canReturnToApp
        self.signedInServers = signedInServers
        self.onMediaBrowserServerSelected = onMediaBrowserServerSelected
        self.onPlexAuthenticated = onPlexAuthenticated
        self.onPlexAuthenticatedMany = onPlexAuthenticatedMany
        self.onShareConfigured = onShareConfigured
        self.onWebDAVShareConfigured = onWebDAVShareConfigured
        self.onMediaShareConfigured = onMediaShareConfigured
        self.onCancel = onCancel
        // Seed the flow's starting screen. Cancelling Quick Connect returns here
        // with the provider preserved so we land on its server list, not the
        // chooser. Plex has no intermediate list, so it falls back to the chooser.
        _choice = State(initialValue: initialProvider?.usesMediaBrowserAPI == true ? initialProvider : nil)
        _plexAuthViewModel = State(initialValue: PlexAuthViewModel(
            service: PlexAuthService(deviceID: deviceID),
            onAuthenticated: onPlexAuthenticated,
            onAuthenticatedMany: onPlexAuthenticatedMany
        ))
    }

    var body: some View {
        ZStack {
            ZStack { pageContent }
                .id(pageID)
                // Resolve the page's geometry once at this boundary instead of
                // pushing the transition down to independently hosted focus rows.
                .geometryGroup()
                .transition(pageTransition)
                .allowsHitTesting(!isTransitioning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let overflowing scroll content reach the physical window edges. The
        // window remains the final clip for the full-page directional push.
        .ignoresSafeArea(.container, edges: .vertical)
        .onChange(of: plexAuthViewModel.phase) { _, phase in
            continueToPreparedPlexPage(for: phase)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch choice {
        case .none:
            chooser
        case .jellyfin:
            ServerPickerView(
                provider: .jellyfin,
                isPageReady: pageIsReady,
                signedInServers: signedInServers.filter { $0.server.provider == .jellyfin },
                onBack: navigateBackToChooser
            ) { onMediaBrowserServerSelected($0) }
        case .emby:
            ServerPickerView(
                provider: .emby,
                isPageReady: pageIsReady,
                signedInServers: signedInServers.filter { $0.server.provider == .emby },
                onBack: navigateBackToChooser
            ) { onMediaBrowserServerSelected($0) }
        case .plex:
            PlexLinkView(
                viewModel: plexAuthViewModel,
                onCancel: navigateBackToChooser
            )
        case .mediaShare:
            AddMediaShareView(
                isPageReady: pageIsReady,
                onBack: navigateBackToChooser,
                onSMBConfigured: onShareConfigured,
                onWebDAVConfigured: onWebDAVShareConfigured,
                onMediaShareConfigured: onMediaShareConfigured
            )
        }
    }

    private var chooser: some View {
        ProviderChooserView(
            showsBranding: !canReturnToApp,
            showsBackButton: canReturnToApp,
            isPreparingPlex: isPreparingPlex,
            onBack: cancelPreparationOrReturn,
            onSelect: navigate(to:)
        )
    }

    private var pageTransition: AnyTransition {
        OnboardingPageMotion.transition(
            direction: navigationDirection,
            reduceMotion: reduceMotion
        )
    }

    private var pageID: String {
        switch choice {
        case .none: "providerChooser"
        case .jellyfin: "jellyfin"
        case .emby: "emby"
        case .plex: "plex"
        case .mediaShare: "mediaShare"
        }
    }

    private func navigate(to destination: ProviderKind) {
        if destination == .plex {
            guard !isPreparingPlex, !isTransitioning else { return }
            isPreparingPlex = true
            plexAuthViewModel.start()
            return
        }
        transition(to: destination, direction: .forward)
    }

    private func continueToPreparedPlexPage(for phase: PlexAuthViewModel.Phase) {
        guard isPreparingPlex else { return }
        switch phase {
        case .idle, .requesting:
            return
        case .awaitingLink, .loadingServers, .selectingServer, .error:
            isPreparingPlex = false
            transition(to: .plex, direction: .forward)
        }
    }

    private func cancelPreparationOrReturn() {
        if isPreparingPlex {
            isPreparingPlex = false
            plexAuthViewModel.cancel()
        } else {
            onCancel()
        }
    }

    private func navigateBackToChooser() {
        transition(to: nil, direction: .backward)
    }

    private func transition(to destination: ProviderKind?, direction: OnboardingNavigationDirection) {
        guard !isTransitioning else { return }

        isTransitioning = true
        pageIsReady = false
        navigationDirection = direction
        withAnimation(
            OnboardingPageMotion.animation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            choice = destination
        } completion: {
            pageIsReady = true
            isTransitioning = false
        }
    }
}

private enum ProviderChooserFocus: Hashable {
    case back
    case jellyfin
    case emby
    case plex
    case mediaShare

    init(provider: ProviderKind) {
        switch provider {
        case .jellyfin: self = .jellyfin
        case .emby: self = .emby
        case .plex: self = .plex
        case .mediaShare: self = .mediaShare
        }
    }
}

private struct ProviderChooserView: View {
    let showsBranding: Bool
    let showsBackButton: Bool
    let isPreparingPlex: Bool
    let onBack: () -> Void
    let onSelect: (ProviderKind) -> Void
    @FocusState private var focusedControl: ProviderChooserFocus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 72) {
                if showsBranding {
                    FirstRunBranding()
                }

                ProviderChoiceGroup(
                    focusedControl: $focusedControl,
                    isPreparingPlex: isPreparingPlex,
                    onSelect: onSelect
                )
                .allowsHitTesting(!isPreparingPlex)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsBackButton {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .back)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        .defaultFocus($focusedControl, .jellyfin)
        .onAppear { focusedControl = .jellyfin }
        .onMoveCommand(perform: bridgeBackButtonFocus)
        .onExitCommand {
            if showsBackButton || isPreparingPlex { onBack() }
        }
    }

    private func bridgeBackButtonFocus(_ direction: MoveCommandDirection) {
        guard showsBackButton else { return }
        switch (focusedControl, direction) {
        case (.some(.jellyfin), .left),
             (.some(.emby), .left),
             (.some(.plex), .left),
             (.some(.mediaShare), .left):
            focusedControl = .back
        case (.some(.back), .right):
            focusedControl = .jellyfin
        default:
            break
        }
    }
}

private struct FirstRunBranding: View {
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
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
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 480)
    }
}

private struct ProviderChoiceGroup: View {
    let focusedControl: FocusState<ProviderChooserFocus?>.Binding
    let isPreparingPlex: Bool
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProviderChoiceRow(
                provider: .jellyfin,
                title: "Jellyfin",
                height: 108,
                focusedControl: focusedControl
            ) {
                onSelect(.jellyfin)
            }

            Divider().padding(.horizontal, 1)

            ProviderChoiceRow(
                provider: .plex,
                title: "Plex",
                height: 108,
                isLoading: isPreparingPlex,
                focusedControl: focusedControl
            ) {
                onSelect(.plex)
            }

            Divider().padding(.horizontal, 1)

            ProviderChoiceRow(
                provider: .emby,
                title: "Emby",
                height: 108,
                focusedControl: focusedControl
            ) {
                onSelect(.emby)
            }

            Divider().padding(.horizontal, 1)

            ProviderChoiceRow(
                provider: .mediaShare,
                title: "Media Share",
                height: 108,
                focusedControl: focusedControl
            ) {
                onSelect(.mediaShare)
            }
        }
        .frame(width: 720)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
        )
    }
}

private struct ProviderChoiceRow: View {
    let provider: ProviderKind
    let title: LocalizedStringKey
    let height: CGFloat
    var isLoading = false
    let focusedControl: FocusState<ProviderChooserFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                ProviderBrandMark(provider: provider, size: 64)

                Text(title)
                    .font(.system(size: 32, weight: .semibold))

                Spacer(minLength: 24)

                if isLoading {
                    ProviderLoadingIndicator()
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 22, weight: .semibold))
                        .settingsRowSecondary()
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .focused(focusedControl, equals: ProviderChooserFocus(provider: provider))
        .padding(12)
    }
}

private struct ProviderLoadingIndicator: View {
    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.settingsRowFocusForeground) private var focusForeground

    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .tint(isFocused ? focusForeground : .accentColor)
            .accessibilityLabel("Requesting a code")
    }
}

#endif
