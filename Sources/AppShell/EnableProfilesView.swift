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

    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private var highlights: [Highlight] {
        [
            Highlight(
                icon: "star.fill",
                text: "Each profile has its own settings and Home layout."
            ),
            Highlight(
                icon: "appletv.fill",
                text: "Plozz remembers the last profile used by each Apple TV user."
            ),
            Highlight(
                icon: "externaldrive.fill",
                text: "Choose which servers each profile can use."
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 140, height: 140)
                    .background(Circle().fill(palette.accent.opacity(0.16)))

                Text("Use profiles on this Apple TV?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                ForEach(highlights) { highlight in
                    highlightCard(highlight)
                }
            }
            .frame(maxWidth: 1040)

            HStack(spacing: 24) {
                Button {
                    appState.declineProfilesForFirstRun()
                } label: {
                    Text("Not now")
                        .frame(minWidth: 300)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .notNow)

                Button {
                    appState.enableProfilesForFirstRun()
                } label: {
                    Text("Use Profiles")
                        .fontWeight(.semibold)
                        .frame(minWidth: 300)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .setup)
            }
            .padding(.top, 8)

            Text("You can enable Profiles later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, .setup)
        // Pressing Menu here declines profiles and continues, so the app never
        // suspends from this one-time setup screen.
        .onExitCommand { appState.declineProfilesForFirstRun() }
    }

    private func highlightCard(_ highlight: Highlight) -> some View {
        HStack(spacing: 24) {
            Image(systemName: highlight.icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 48)

            Text(highlight.text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
#endif
