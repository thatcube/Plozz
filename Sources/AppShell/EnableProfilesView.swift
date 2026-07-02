#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// One-time first-run prompt (brand-new install only) asking whether to enable
/// multiple Plozz **profiles** for this Apple TV. Shown after the first server
/// is added (and, for Plex, after the "Which Plex user are you?" pick).
///
/// - "Set Up Profiles" turns the feature on (`AppState.enableProfilesForFirstRun`)
///   and continues to the confirm screen, where the seeded profile can be kept
///   or edited.
/// - "Not Now — Just Me" keeps profiles hidden/disabled and drops straight into
///   the app with the single seeded profile
///   (`AppState.declineProfilesForFirstRun`).
///
/// It never appears again once first-run setup completes; profiles can still be
/// enabled later in Settings.
struct EnableProfilesView: View {
    @Bindable var appState: AppState
    @Environment(\.themePalette) private var palette
    @FocusState private var focus: Field?

    private enum Field { case setup, notNow }

    var body: some View {
        VStack(spacing: 44) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 90, weight: .semibold))
                    .foregroundStyle(palette.accent)

                VStack(spacing: 16) {
                    Text("Set up profiles for this Apple TV?")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text("Profiles keep separate favorites, watch history, and Home layouts for each person. A profile is tied to an Apple TV user, so switching users on your Apple TV switches your Plozz profile too. Your servers stay shared no matter who’s watching.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 24) {
                Button {
                    appState.declineProfilesForFirstRun()
                } label: {
                    Text("Not Now — Just Me")
                        .frame(minWidth: 300)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .notNow)

                Button {
                    appState.enableProfilesForFirstRun()
                } label: {
                    Text("Set Up Profiles")
                        .fontWeight(.semibold)
                        .frame(minWidth: 300)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .setup)
            }

            Text("You can turn this on later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, .setup)
        // Pressing Menu here declines profiles and continues, so the app never
        // suspends from this one-time setup screen.
        .onExitCommand { appState.declineProfilesForFirstRun() }
    }
}
#endif
