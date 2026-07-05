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
    /// instant a card is tapped, in both the onboarding and cover flows. `.system`
    /// resolves against `SystemAppearance.colorScheme` (the screen's real scheme,
    /// which our `preferredColorScheme` override can't pollute).
    private var livePalette: ThemePalette {
        ThemePalette.palette(for: selectedTheme, systemColorScheme: SystemAppearance.colorScheme)
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
        // Force a CONCRETE scheme (never nil) derived from the resolved palette,
        // so System follows the real device appearance and switching away from a
        // forced Light/Dark never gets stuck (matches RootView).
        .preferredColorScheme(livePalette.isLight ? .light : .dark)
        .onAppear { focus = .theme(selectedTheme) }
        // Pressing Menu accepts the current selection, so the app never suspends
        // from this one-time setup screen.
        .onExitCommand { onContinue() }
    }

    // MARK: Theme card

    @ViewBuilder
    private func themeCard(_ theme: AppTheme) -> some View {
        let isSelected = theme == selectedTheme

        Button {
            // Apply immediately for a full-page live preview.
            appState.themeModel.theme = theme
        } label: {
            VStack(spacing: 18) {
                ThemePreviewSwatch(theme: theme)
                    .frame(height: 200)

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
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
                        .lineLimit(2, reservesSpace: true)
                }
            }
        }
        // A custom ButtonStyle OWNS the focus look (not `.plain` + a manual
        // overlay, which still lets tvOS paint its default focus fill). This is
        // exactly how the profile tiles and Settings' About panel show focus:
        // a soft accent outline around the whole card. `.focusEffectDisabled()`
        // drops the system focus halo so the outline is the only indicator.
        .buttonStyle(ThemeCardButtonStyle(accent: livePalette.accent, isSelected: isSelected))
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
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ThemeCardButtonBody(configuration: configuration, accent: accent, isSelected: isSelected)
    }
}

private struct ThemeCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    private var corner: CGFloat { PlozzTheme.Metrics.mediumCardCornerRadius }

    var body: some View {
        configuration.label
            .frame(width: 320)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        // Accent wash marks the ACTIVE theme so selection reads
                        // at a glance, even when another card is focused.
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(accent.opacity(isSelected ? 0.22 : 0))
                    )
            )
            // Resting border: a soft accent ring when selected, else a hairline.
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.7) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
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
            .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

/// Fixed, theme-independent colours for a preview swatch. Deliberately NOT
/// derived from `ThemePalette` or the environment colour scheme: a swatch is a
/// *picture* of a theme, so it must always show that theme's own look no matter
/// which theme is currently applied (previously the swatches shifted with the
/// selected theme because they resolved against the overridden colour scheme).
private struct ThemePreviewColors {
    let bgTop: Color
    let bgBottom: Color
    let card: Color
    let cardBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let accent: Color

    /// One fixed accent for every swatch, so the graphics never pick up the
    /// app's (theme-tinted) accent.
    static let accentBlue = Color(red: 0.20, green: 0.60, blue: 1.0)

    static let light = ThemePreviewColors(
        bgTop: Color(white: 1.0),
        bgBottom: Color(white: 0.93),
        card: Color(white: 0.99),
        cardBorder: Color.black.opacity(0.10),
        textPrimary: Color.black.opacity(0.80),
        textSecondary: Color.black.opacity(0.42),
        accent: accentBlue
    )
    static let dark = ThemePreviewColors(
        bgTop: Color(red: 0.17, green: 0.17, blue: 0.19),
        bgBottom: Color(red: 0.10, green: 0.10, blue: 0.12),
        card: Color(red: 0.26, green: 0.26, blue: 0.29),
        cardBorder: Color.white.opacity(0.12),
        textPrimary: Color.white.opacity(0.90),
        textSecondary: Color.white.opacity(0.45),
        accent: accentBlue
    )
    static let oled = ThemePreviewColors(
        bgTop: .black,
        bgBottom: .black,
        card: Color(white: 0.11),
        cardBorder: Color.white.opacity(0.16),
        textPrimary: Color.white.opacity(0.92),
        textSecondary: Color.white.opacity(0.45),
        accent: accentBlue
    )
}

/// A tiny mock "Home screen" painted with a fixed `ThemePreviewColors`. Sizes
/// everything relative to its own width so it reads correctly at full width
/// (Light/Dark/OLED) and at half width (each side of the System split).
private struct MiniPreview: View {
    let colors: ThemePreviewColors

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pad = w * 0.09
            let content = w - pad * 2
            let gap = w * 0.045
            let cardW = (content - gap * 2) / 3
            let bar = max(3.0, w * 0.024)

            VStack(alignment: .leading, spacing: w * 0.05) {
                // Faux title bar.
                HStack(spacing: w * 0.03) {
                    Capsule().fill(colors.accent).frame(width: w * 0.16, height: bar)
                    Capsule().fill(colors.textSecondary).frame(width: w * 0.28, height: bar)
                }
                // Faux poster row.
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: w * 0.035, style: .continuous)
                            .fill(colors.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: w * 0.035, style: .continuous)
                                    .strokeBorder(colors.cardBorder, lineWidth: 1)
                            )
                            .frame(width: cardW, height: cardW * 1.35)
                            .overlay(alignment: .bottomLeading) {
                                Capsule()
                                    .fill(index == 0 ? colors.accent : colors.textSecondary)
                                    .frame(width: cardW * 0.55, height: bar * 0.8)
                                    .padding(w * 0.02)
                            }
                    }
                }
                // Faux text lines.
                Capsule().fill(colors.textPrimary).frame(width: content * 0.6, height: bar)
                Capsule().fill(colors.textSecondary).frame(width: content * 0.42, height: bar)
                Spacer(minLength: 0)
            }
            .padding(pad)
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .background(
                LinearGradient(colors: [colors.bgTop, colors.bgBottom], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

/// The per-option preview graphic. Light/Dark/OLED show their own fixed look;
/// System is split half-light / half-dark to signal "follows your device."
private struct ThemePreviewSwatch: View {
    let theme: AppTheme
    private let corner: CGFloat = 16

    var body: some View {
        Group {
            switch theme {
            case .system:
                // One continuous UI, split down the middle: the left half is
                // painted light, the right half dark, so the centre poster card
                // straddles the seam. Both layers render the IDENTICAL full-width
                // layout, then each is masked to its half so every element lines
                // up exactly across the split. The light layer overruns the seam
                // by 0.5pt (and sits under the dark layer) to avoid a hairline gap.
                GeometryReader { geo in
                    ZStack {
                        MiniPreview(colors: .light)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width / 2 + 0.5)
                            }
                        MiniPreview(colors: .dark)
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: geo.size.width / 2)
                            }
                    }
                }
            case .light:
                MiniPreview(colors: .light)
            case .dark:
                MiniPreview(colors: .dark)
            case .oled:
                MiniPreview(colors: .oled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        )
    }
}
#endif
