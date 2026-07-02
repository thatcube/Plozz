#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings ▸ "What Plozz Can Do" — the re-viewable version of the first-run
/// welcome. Renders the same data-driven `OnboardingHighlight.defaultHighlights`
/// through the shared `CoreUI.OnboardingHighlightsView`, so a user who skipped or
/// forgot the welcome can revisit every feature at any time (and the two surfaces
/// never drift). Read-only: no toggles, no persistence.
struct FeatureTourDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Everything Plozz brings to your Plex and Jellyfin libraries. Explore Settings to set each of these up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingHighlightsView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
    }
}

#endif
