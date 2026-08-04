#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

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

    public init(scope: ProfileLibrariesScope, onDone: @escaping () -> Void) {
        self.scope = scope
        self.onDone = onDone
    }

    @Environment(\.themePalette) private var palette
    @State private var path: [SettingsRoute] = []

    public var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppBackground(palette: palette).ignoresSafeArea()
                VStack(spacing: 0) {
                    MyLibrariesDetailView(scope: scope)
                    doneBar
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                // The only route this screen can push.
                if case let .plexUser(accountID) = route {
                    PlexLinkedUserDetailView(scope: scope, accountID: accountID)
                }
            }
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
