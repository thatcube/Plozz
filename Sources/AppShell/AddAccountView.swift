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
    let onJellyfinServerSelected: (MediaServer) -> Void
    let onPlexAuthenticated: (UserSession) -> Void
    let onCancel: () -> Void

    @State private var choice: ProviderKind?

    var body: some View {
        switch choice {
        case .none:
            chooser
        case .jellyfin:
            ServerPickerView(onBack: { choice = nil }) { onJellyfinServerSelected($0) }
        case .plex:
            PlexLinkView(
                viewModel: PlexAuthViewModel(
                    service: PlexAuthService(deviceID: deviceID),
                    onAuthenticated: onPlexAuthenticated
                ),
                onCancel: { choice = nil }
            )
        }
    }

    private var chooser: some View {
        VStack(spacing: 40) {
            HStack(spacing: 32) {
                providerButton(
                    provider: .jellyfin,
                    detail: "Find it on your network or enter an address."
                ) { choice = .jellyfin }

                providerButton(
                    provider: .plex,
                    detail: "Link this device at plex.tv/link."
                ) { choice = .plex }
            }

            if canReturnToApp {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(width: 420, height: 320)
        }
        // Same focus treatment as the Settings About / Report a Problem cards:
        // accent outline + gentle lift, no contrast inversion.
        .buttonStyle(SettingsCardButtonStyle())
    }
}

#endif
