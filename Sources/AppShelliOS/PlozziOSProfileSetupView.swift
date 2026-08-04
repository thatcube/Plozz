#if os(iOS)
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI

/// The new-profile setup step on iOS: the REAL Libraries screen, with Done.
///
/// Deliberately not a second implementation, for the same reason the tvOS step
/// reuses its Libraries screen. Setup asks exactly what Settings → Libraries
/// asks — which servers this profile uses, who it watches as on each, and which
/// libraries it shows — so it shows that screen rather than a lookalike that
/// would drift from it.
///
/// It differs from tvOS only in which screen that is: iOS's Libraries page is a
/// `Form`, and the tvOS one is a focus-driven list. The *policy* the two share
/// (the gate, when it lifts, what happens next) lives in the model.
struct PlozziOSProfileSetupView: View {
    let appModel: PlozziOSAppModel
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel,
                onAddServer: {},
                presentation: .profileSetup
            )
            .navigationTitle("Set Up \(appModel.profiles.activeProfile.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .safeAreaInset(edge: .top) {
                Text(
                    "Pick the servers \(appModel.profiles.activeProfile.name) watches with, and who they are on each."
                )
                .font(.subheadline)
                .plozzForeground(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        // Setup has to finish deliberately: the model releases the watchlist
        // import when it does, so a swipe-away is handled as an explicit cancel
        // rather than being allowed to strand the profile mid-flow.
        .interactiveDismissDisabled()
    }
}

/// Asks who a profile watches as on a Plex server it just switched on.
///
/// Reuses the Home-user page from Settings, which is already the screen for this
/// question on iOS — the difference is only that here it's asked rather than
/// gone looking for. See `ProfileServerIdentityPrompts` for why enabling a
/// server later has to ask at all.
struct PlozziOSServerIdentityPromptView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            PlozziOSPlexHomeUserSettingsView(appModel: appModel, account: account)
                .navigationTitle("Who are you on \(account.server.name)?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onFinish)
                    }
                }
        }
    }
}
/// The whole new-profile setup sequence, in ONE cover.
///
/// One cover switching its content rather than a cover per step: presenting on
/// the step itself would tear the cover down and put a new one up each time, and
/// SwiftUI drops a presentation requested while another is still dismissing —
/// which is exactly how the theme step went missing before.
///
/// A view of its own rather than inline in each presenter: both root and the
/// Profiles settings page present this (see `ProfileOnboardingOrigin`), and the
/// iOS root's body is already at the type-checker's budget.
struct PlozziOSProfileOnboardingCover: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        switch appModel.profileOnboardingStep {
        case .libraries:
            PlozziOSProfileSetupView(
                appModel: appModel,
                onDone: { appModel.advanceProfileOnboarding() }
            )
        case .theme:
            NavigationStack {
                PlozziOSThemeWelcomeView(
                    appModel: appModel,
                    onContinue: { appModel.advanceProfileOnboarding() }
                )
            }
        case nil:
            // Reached only in the frame where the last step clears the flag and
            // the cover is on its way out.
            EmptyView()
        }
    }
}
#endif
