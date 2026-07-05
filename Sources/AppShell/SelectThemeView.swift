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
    /// When set, personalises the heading ("Choose <name>'s look") for the
    /// new-profile flow. `nil` uses the generic first-run heading.
    var profileName: String? = nil

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case theme(AppTheme)
        case continueButton
    }

    private var selectedTheme: AppTheme { appState.themeModel.theme }

    private var headline: String {
        if let profileName, !profileName.isEmpty {
            return "Choose \(profileName)'s look"
        }
        return "Choose your look"
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text(headline)
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
        // RootView already paints the same background behind this).
        .background { AppBackground(palette: palette).ignoresSafeArea() }
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
                                .foregroundStyle(palette.accent)
                        }
                    }
                    Text(theme.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 320)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? palette.accent : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .theme(theme))
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
