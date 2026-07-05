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
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case theme(AppTheme)
        case continueButton
    }

    private var selectedTheme: AppTheme { appState.themeModel.theme }

    /// The palette for the currently selected theme, computed straight from the
    /// observable `themeModel` rather than the `\.themePalette` environment.
    /// Custom environment values don't reliably update inside a `fullScreenCover`
    /// (the in-app new-profile flow), which left the backdrop stuck; reading the
    /// model directly re-renders this view — and repaints the background — the
    /// instant a card is tapped, in both the onboarding and cover flows.
    private var livePalette: ThemePalette {
        ThemePalette.palette(for: selectedTheme, systemColorScheme: systemColorScheme)
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text("Choose theme")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Dark looks best for most rooms. You can change this anytime in Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            HStack(alignment: .top, spacing: 28) {
                ForEach(AppTheme.allCases) { theme in
                    themeCard(theme)
                }
            }
            .frame(maxWidth: 1500)

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
        .preferredColorScheme(selectedTheme.preferredColorScheme)
        .onAppear { focus = .theme(selectedTheme) }
        // Pressing Menu accepts the current selection, so the app never suspends
        // from this one-time setup screen.
        .onExitCommand { onContinue() }
    }

    // MARK: Theme card

    @ViewBuilder
    private func themeCard(_ theme: AppTheme) -> some View {
        let isSelected = theme == selectedTheme
        let preview = ThemePalette.palette(for: theme, systemColorScheme: systemColorScheme)

        Button {
            // Apply immediately for a full-page live preview.
            appState.themeModel.theme = theme
        } label: {
            VStack(spacing: 18) {
                ThemePreviewSwatch(palette: preview)
                    .frame(height: 200)

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: theme.symbolName)
                            .font(.headline)
                        Text(theme.displayName)
                            .font(.title3.weight(.semibold))
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(livePalette.accent)
                        }
                    }
                    Text(theme.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A custom ButtonStyle OWNS the focus look (not `.plain` + a manual
        // overlay, which still lets tvOS paint its default focus fill). This is
        // exactly how the profile tiles and Settings' About panel show focus:
        // a soft accent outline around the whole card. `.focusEffectDisabled()`
        // drops the system focus halo so the outline is the only indicator.
        .buttonStyle(ThemeCardButtonStyle(accent: livePalette.accent))
        .focusEffectDisabled()
        .focused($focus, equals: .theme(theme))
    }
}

/// Focus look for a theme card, mirroring `FocusableSettingsPanel` (Settings'
/// About panel) and the profile tiles: a resting hairline border, and on focus a
/// soft 4pt accent outline blooming around the whole card plus a gentle shadow +
/// 1.01 lift — never the inverted/filled tvOS focus background.
///
/// Implemented as a `ButtonStyle` reading `\.isFocused` (rather than a `.plain`
/// button with a manual overlay) so the system focus fill never draws. The
/// accent is passed in — not read from `\.themePalette` — because that custom
/// environment value doesn't reliably reach a `fullScreenCover`.
private struct ThemeCardButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        ThemeCardButtonBody(configuration: configuration, accent: accent)
    }
}

private struct ThemeCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    @Environment(\.isFocused) private var isFocused

    private var corner: CGFloat { PlozzTheme.Metrics.mediumCardCornerRadius }

    var body: some View {
        configuration.label
            .frame(width: 320)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            // Resting hairline border, matching every SettingsPanel.
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            // Focus outline (accent), shown only when focused.
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(accent, lineWidth: 4)
                    .opacity(isFocused ? 1 : 0)
            )
            .shadow(color: .black.opacity(isFocused ? 0.28 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 6 : 0)
            .scaleEffect(isFocused ? 1.01 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// A small, self-contained mock of a Home screen painted with a given
/// `ThemePalette`, so each option previews its true colours regardless of the
/// theme currently applied to the app.
private struct ThemePreviewSwatch: View {
    let palette: ThemePalette

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [palette.backgroundBase, palette.backgroundSecondary],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    // Faux title bar.
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.accent)
                            .frame(width: 44, height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(palette.secondaryText.opacity(0.5))
                            .frame(width: 70, height: 8)
                    }

                    // Faux card row.
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.cardSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(palette.cardBorder, lineWidth: 1)
                                )
                                .frame(width: 60, height: 84)
                                .overlay(alignment: .bottomLeading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(index == 0 ? palette.accent : palette.secondaryText.opacity(0.4))
                                        .frame(width: 34, height: 5)
                                        .padding(6)
                                }
                        }
                    }

                    // Faux text lines.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.primaryText.opacity(0.85))
                        .frame(width: 130, height: 7)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.secondaryText.opacity(0.5))
                        .frame(width: 96, height: 7)
                }
                .padding(16)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
    }
}
#endif
