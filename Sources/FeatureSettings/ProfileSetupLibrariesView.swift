#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Navigation state owned by the outer profile-setup flow.
///
/// Add-user authentication temporarily overlays/rebuilds the Libraries view. If
/// the path lives inside that child, SwiftUI may recreate it at `[]` and return
/// too far to "What does this profile watch?". Keeping this reference in the
/// persistent flow preserves the exact Watching as destination.
public final class ProfileSetupNavigationState: ObservableObject {
    @Published var path: [SettingsRoute] = []

    public init() {}
}

/// The new-profile setup step: the REAL Libraries screen, with a Done button.
///
/// Deliberately not a second implementation. Setup asks exactly what Settings →
/// Libraries asks — which servers this profile uses, who it watches as on each,
/// and which libraries it shows — so it renders that screen rather than a
/// lookalike. The first attempt at this step was a parallel list that detached
/// libraries from their servers and rebuilt rows without the focus-aware
/// modifiers, which is precisely the drift a second copy produces.
///
/// Owns its own `NavigationStack` because the Libraries screen pushes the Plex
/// Home-user picker, and this is presented as a cover rather than inside
/// Settings' stack.
public struct ProfileSetupLibrariesView: View {
    private let scope: ProfileLibrariesScope
    private let onDone: () -> Void
    @ObservedObject private var navigationState: ProfileSetupNavigationState

    public init(
        scope: ProfileLibrariesScope,
        navigationState: ProfileSetupNavigationState = ProfileSetupNavigationState(),
        onDone: @escaping () -> Void
    ) {
        self.scope = scope
        self.navigationState = navigationState
        self.onDone = onDone
    }

    @Environment(\.themePalette) private var palette
    public var body: some View {
        // The background sits OUTSIDE the NavigationStack. Inside its root
        // content it belonged to the root view, so pushing "Watching as"
        // replaced it — leaving the pushed page transparent and showing Home
        // through the cover. Out here it backs every page in the stack.
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            NavigationStack(path: $navigationState.path) {
                VStack(spacing: 0) {
                    MyLibrariesDetailView(scope: scope)
                    doneBar
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    // Both identity pages the Libraries screen can push. Missing
                    // one here would dead-end that row during setup only, which
                    // is exactly the kind of divergence reusing the screen is
                    // meant to prevent.
                    switch route {
                    case let .plexUser(accountID):
                        PlexLinkedUserDetailView(scope: scope, accountID: accountID)
                    case let .serverUser(serverKey):
                        ServerUserDetailView(scope: scope, serverKey: serverKey)
                    default:
                        EmptyView()
                    }
                }
            }
            // The stack's own surface would otherwise paint over the shared
            // background on every page.
            .background(Color.clear)
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
    }

    /// Pinned under the list so "Done" is always reachable — the library list can
    /// be long, and setup must not be something you can only leave by scrolling
    /// to the bottom.
    private var doneBar: some View {
        HStack {
            Spacer()
            Button(action: onDone) {
                Text("Done").frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.vertical, 24)
        .tvOSFocusSection()
    }
}
#endif
