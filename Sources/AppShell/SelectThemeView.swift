#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// One-time theme picker shown when a profile is first set up.
///
/// Two entry points, both driven by the same view:
/// - **First run** — rendered by `RootView` in the onboarding flow, right after
///   profile setup (`onContinue` fires `AppState.finishThemeSelection`).
/// - **New in-app profile** — presented as a full-screen cover after Settings →
///   "Add Profile" switches to the freshly created profile (`onContinue` fires
///   `AppState.finishNewProfileThemeSelection`).
///
/// Selecting a theme applies it **live**: `RootView` derives its palette and
/// `preferredColorScheme` from `appState.themeModel.theme`, so pressing an option
/// repaints the whole screen immediately. Each card also renders an independent
/// mini-preview built from that theme's own palette, so all four looks can be
/// compared at a glance. "Continue" commits the choice and dismisses.
///
/// Never appears again once setup completes; the theme can still be changed
/// later in Settings → Appearance.
struct SelectThemeView: View {
    @Bindable var appState: AppState
    /// Called when the user accepts their choice (Continue, or Menu). The caller
    /// decides what "done" means (enter the app, or dismiss the cover).
    var onContinue: () -> Void
    /// The real device colour scheme, passed in from RootView (which reads it
    /// unpolluted). Used to resolve `.system`; passed explicitly rather than read
    /// from `@Environment` because that value can be stale inside a
    /// `fullScreenCover` (the in-app new-profile flow).
    var deviceColorScheme: ColorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case theme(AppTheme)
        case continueButton
    }

    private var selectedTheme: AppTheme { appState.themeModel.theme }

    /// The palette for the currently selected theme, computed straight from the
    /// observable `themeModel` (so it repaints the instant a card is tapped, in
    /// both the onboarding and cover flows). `.system` resolves against the
    /// passed-in `deviceColorScheme`.
    private var livePalette: ThemePalette {
        ThemePalette.palette(for: selectedTheme, systemColorScheme: deviceColorScheme)
    }

    /// Personalised when profiles are on; plain otherwise (e.g. the user chose
    /// "Not Now — Just Me" on first run).
    private var title: String {
        appState.profilesModel.profilesEnabled ? "Choose theme for this profile" : "Choose theme"
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            Text(title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: 28) {
                ForEach(AppTheme.pickerOrder) { theme in
                    themeCard(theme)
                }
            }
            .frame(maxWidth: 1500)
            // Group the cards into one focus section so moving DOWN from any card
            // (incl. the far-left System / far-right OLED) reliably exits to the
            // Continue button below, instead of the focus engine giving up because
            // the centred button isn't directly beneath the edge cards.
            .focusSection()

            // Full-width focus region for the Continue button (via a centring
            // ZStack) so a straight-down move from any card lands on it regardless
            // of horizontal alignment.
            ZStack {
                Button {
                    onContinue()
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(minWidth: 360)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
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
        // Own themed backdrop so the page previews the selected look even when
        // presented as a full-screen cover over the app (in the first-run flow
        // RootView already paints the same background behind this). Driven by
        // `livePalette` so it repaints the moment a card is tapped.
        .background { AppBackground(palette: livePalette).ignoresSafeArea() }
        // Push the effective scheme DOWN via the environment (not
        // `preferredColorScheme`, which forces the window and pollutes the device
        // scheme). Matches RootView so System follows the device.
        .environment(\.colorScheme, livePalette.isLight ? .light : .dark)
        .onAppear { focus = .theme(selectedTheme) }
        // Pressing Menu accepts the current selection, so the app never suspends
        // from this one-time setup screen.
        .onExitCommand { onContinue() }
    }

    // MARK: Theme card

    @ViewBuilder
    private func themeCard(_ theme: AppTheme) -> some View {
        ThemeOptionCard(
            theme: theme,
            isSelected: theme == selectedTheme,
            accent: livePalette.accent,
            action: { appState.themeModel.theme = theme }
        )
        .focused($focus, equals: .theme(theme))
    }
}

#endif
