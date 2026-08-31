#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Shared navigation picker for first run, new profiles, and feature onboarding.
///
/// Selection applies live to the active profile. Every entry point uses this
/// same screen so an existing choice remains selected without special-case copy.
struct SelectNavigationStyleView: View {
    @Bindable var appState: AppState
    let onContinue: () -> Void
    @Environment(\.themePalette) private var palette
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case style(NavigationStyle)
        case continueButton
    }

    private var selectedStyle: NavigationStyle {
        appState.profileSettings.navigationStyleModel.style
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            Text("Choose navigation for this profile")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: 28) {
                ForEach(NavigationStyle.allCases) { style in
                    styleCard(style)
                }
            }
            .frame(maxWidth: 1500)
            .focusSection()

            ZStack {
                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                        .frame(minWidth: 360)
                }
                .plozzActionButton()
                .focused($focus, equals: .continueButton)
            }
            .frame(maxWidth: .infinity)
            .focusSection()
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground(palette: palette).ignoresSafeArea() }
        .onAppear { focus = .style(selectedStyle) }
        .onExitCommand { onContinue() }
    }

    private func styleCard(_ style: NavigationStyle) -> some View {
        PreviewCard(
            title: style.displayName,
            detail: style.detail,
            isSelected: style == selectedStyle,
            accent: palette.accent,
            action: { appState.profileSettings.navigationStyleModel.style = style }
        ) {
            NavigationStyleSwatch(
                style: style,
                cornerRadius: PlozzTheme.Metrics.Radius.content
            )
        }
        .focused($focus, equals: .style(style))
    }
}

/// Keeps Theme and Navigation inside one cover for newly-created profiles.
struct NewProfileAppearanceFlowView: View {
    let appState: AppState
    let deviceColorScheme: ColorScheme
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Stage = .theme

    private enum Stage {
        case theme
        case navigation
    }

    var body: some View {
        ZStack {
            switch stage {
            case .theme:
                SelectThemeView(
                    appState: appState,
                    onContinue: {
                        withAnimation(
                            OnboardingPageMotion.animation(reduceMotion: reduceMotion)
                        ) {
                            stage = .navigation
                        }
                    },
                    deviceColorScheme: deviceColorScheme
                )
                .transition(
                    OnboardingPageMotion.transition(
                        direction: .forward,
                        reduceMotion: reduceMotion
                    )
                )
            case .navigation:
                SelectNavigationStyleView(
                    appState: appState,
                    onContinue: onComplete
                )
                .transition(
                    OnboardingPageMotion.transition(
                        direction: .forward,
                        reduceMotion: reduceMotion
                    )
                )
            }
        }
    }
}
#endif
