#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// First-run welcome shown once after the first account is added, before the
/// user lands in Home. Its job is feature discovery: a new user has just
/// connected a server, and this is the one moment to surface what makes Plozz
/// different — dual-provider libraries, profiles, trackers, cinema playback, and
/// the customization waiting in Settings.
///
/// Content is data-driven (`OnboardingHighlight.defaultHighlights`) and rendered
/// by the shared `CoreUI.OnboardingHighlightsView`, so this screen and the
/// Settings "What Plozz Can Do" page stay in lockstep. The "seen" flag is owned
/// by `RootView` (app-wide `OnboardingWelcome`); this view just reports the tap.
struct WelcomeView: View {
    /// Invoked when the user dismisses the welcome. `RootView` records that the
    /// welcome has been seen and swaps in the main app.
    let onGetStarted: () -> Void

    @Environment(\.themePalette) private var palette
    @FocusState private var getStartedFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 64)
                .padding(.bottom, 40)

            ScrollView {
                OnboardingHighlightsView()
                    .padding(.horizontal, 90)
                    .padding(.bottom, 48)
            }
            .scrollClipDisabled()

            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.headline)
                    .frame(minWidth: 360)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .focused($getStartedFocused)
            .padding(.bottom, 44)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Land focus on the primary action so a single click proceeds; the user
        // can move up to browse the highlight cards if they want.
        .defaultFocus($getStartedFocused, true)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Text("Welcome to Plozz")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.primaryText)
            Text("One app for all your Plex and Jellyfin libraries. Here's what you can do:")
                .font(.title3)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1100)
        }
    }
}

#endif
