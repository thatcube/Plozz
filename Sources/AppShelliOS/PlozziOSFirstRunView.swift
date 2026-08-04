#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureProfiles
import Foundation
import SwiftUI

struct PlozziOSFirstRunView: View {
    /// Optional so the view can hold the last real step on screen while the cover
    /// dismisses — otherwise the final step would blank out before the animation
    /// finished, flashing Home.
    let step: PlozziOSAppModel.FirstRunStep?
    let appModel: PlozziOSAppModel
    let systemColorScheme: ColorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedStep: PlozziOSAppModel.FirstRunStep
    @State private var direction: OnboardingNavigationDirection = .forward
    /// The Plex-user step clears the model's selection before the next step is
    /// scheduled, so hold the last real payload to render from. Without it the
    /// step blanks for a frame mid-transition.
    @State private var lastPlexSelection: PlexHomeUsersModel.PendingPlexUserSelection?

    init(
        step: PlozziOSAppModel.FirstRunStep?,
        appModel: PlozziOSAppModel,
        systemColorScheme: ColorScheme
    ) {
        self.step = step
        self.appModel = appModel
        self.systemColorScheme = systemColorScheme
        _displayedStep = State(initialValue: step ?? .confirmProfile)
    }

    var body: some View {
        ZStack {
            stepContent
                .id(displayedStep)
                .geometryGroup()
                // Same motion the tvOS onboarding flow uses, so the two
                // platforms move alike and honour Reduce Motion the same way.
                .transition(
                    OnboardingPageMotion.transition(
                        direction: direction,
                        reduceMotion: reduceMotion
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: step) { _, newStep in
            // nil means the flow finished; keep the current screen rendered so
            // the cover slides away over it rather than over an empty view.
            guard let newStep, newStep != displayedStep else { return }
            direction = newStep.order >= displayedStep.order ? .forward : .backward
            withAnimation(OnboardingPageMotion.animation(reduceMotion: reduceMotion)) {
                displayedStep = newStep
            }
        }
        .onChange(of: appModel.plexHomeUsers.pendingPlexUserSelection) { _, selection in
            if let selection { lastPlexSelection = selection }
        }
        .task {
            lastPlexSelection = appModel.plexHomeUsers.pendingPlexUserSelection
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground(palette: palette) }
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .toolbarBackground(.hidden, for: .navigationBar)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var stepContent: some View {
        switch displayedStep {
        case .plexUser:
            if let selection = appModel.plexHomeUsers.pendingPlexUserSelection
                ?? lastPlexSelection {
                PlozziOSPlexUserSelectionView(
                    selection: selection,
                    onSelect: appModel.selectPlexUserDuringOnboarding
                )
            }
        case .libraries:
            if let selection = appModel.pendingLibrarySelection {
                PlozziOSLibrarySelectionView(
                    accounts: appModel.accountsProviders.resolvedAccounts(
                        withIDs: selection.accountIDs
                    ),
                    visibility: appModel.settings.homeVisibility,
                    onContinue: appModel.completeLibrarySelection
                )
            }
        case .confirmProfile:
            PlozziOSFirstProfileView(appModel: appModel)
        case .theme:
            NavigationStack {
                PlozziOSThemeWelcomeView(
                    appModel: appModel,
                    onContinue: appModel.finishFirstRunThemeSelection
                )
            }
        }
    }

    private var palette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }
}

private struct PlozziOSFirstProfileView: View {
    let appModel: PlozziOSAppModel
    @State private var editing = false

    private var profile: Profile { appModel.profiles.activeProfile }

    var body: some View {
        // Centre the column when the screen is taller than the content (every
        // iPad, and iPhone portrait) instead of stranding it at the top with a
        // screenful of dead space below. `minHeight` keeps it scrollable when
        // the content IS taller, e.g. iPhone landscape or large Dynamic Type.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    // Edit sits with the thing it edits, and is a stock bordered
                    // button so it reads as neutral next to the prominent CTA.
                    VStack(spacing: 16) {
                        PlozziOSProfileAvatar(profile: profile, size: 128)

                        Button("Edit") { editing = true }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityHint("Rename this profile or change its picture")
                    }

                    VStack(spacing: 12) {
                        Text(profile.name)
                            .font(.largeTitle.bold())

                        // Two discrete statements rather than one run-on: what a
                        // profile does, then what you can do about it.
                        VStack(spacing: 4) {
                            Text("Almost all settings are saved per profile.")
                            Text("You can add more profiles in Settings.")
                        }
                        .plozzForeground(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    // "Continue" to match the library and theme steps either side
                    // of this one; inline rather than pinned, as they all are.
                    Button("Continue") {
                        appModel.confirmFirstRunProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: false,
                    onFinished: { editing = false }
                )
            }
        }
    }

}

/// The per-profile theme picker.
///
/// Shared by first run and by new-profile setup rather than duplicated: the
/// theme is a per-profile setting, so every new profile gets asked, not just the
/// first one. Only what happens on Continue differs, so only that is injected.
struct PlozziOSThemeWelcomeView: View {
    let appModel: PlozziOSAppModel
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Text("Choose Your Look")
                            .font(.largeTitle.bold())
                        Text("Pick a theme for this profile. You can change it any time.")
                            .plozzForeground(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(AppTheme.pickerOrder) { theme in
                            Button {
                                appModel.settings.theme.theme = theme
                            } label: {
                                VStack(spacing: 14) {
                                    Image(systemName: theme.symbolName)
                                        .font(.system(size: 32, weight: .semibold))
                                    Text(theme.displayName)
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(
                                            appModel.settings.theme.theme == theme
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.2),
                                            lineWidth: appModel.settings.theme.theme == theme ? 3 : 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(
                                appModel.settings.theme.theme == theme ? .isSelected : []
                            )
                        }
                    }

                    Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PlozziOSProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        // Delegate to the shared renderer so the first-run / settings avatars
        // match every other avatar surface (photo, emoji, or symbol on the
        // chosen colour) exactly.
        ProfileAvatarView(profile: profile, size: size)
    }
}

#endif
