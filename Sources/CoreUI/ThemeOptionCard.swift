#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for a preview swatch. Deliberately NOT
/// derived from `ThemePalette` or the environment colour scheme: a swatch is a
/// *picture* of a theme, so it must always show that theme's own look no matter
/// which theme is currently applied.
struct ThemePreviewColors {
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

/// A tiny mock "Home screen" painted with a fixed `ThemePreviewColors`: a title
/// bar, two wide poster tiles, and a couple of text lines sitting toward the top.
/// Horizontal metrics scale with width and vertical metrics with height, so it
/// stays balanced at both the full onboarding size and the shorter, compact
/// Settings size (and at half width, for each side of the System split).
private struct MiniPreview: View {
    let colors: ThemePreviewColors

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padH = w * 0.08
            let padV = h * 0.12
            let contentW = w - padH * 2
            let gap = w * 0.05
            let cardW = (contentW - gap) / 2
            let cardH = h * 0.44
            let vGap = h * 0.07
            let barH = max(3.0, h * 0.045)
            let cardCorner = min(w, h) * 0.05

            VStack(alignment: .leading, spacing: vGap) {
                // Faux title bar.
                HStack(spacing: w * 0.03) {
                    Capsule().fill(colors.accent).frame(width: w * 0.18, height: barH)
                    Capsule().fill(colors.textSecondary).frame(width: w * 0.30, height: barH)
                }
                // Two wide poster tiles.
                HStack(spacing: gap) {
                    ForEach(0..<2, id: \.self) { index in
                        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                            .fill(colors.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                                    .strokeBorder(colors.cardBorder, lineWidth: 1)
                            )
                            .frame(width: cardW, height: cardH)
                            .overlay(alignment: .bottomLeading) {
                                Capsule()
                                    .fill(index == 0 ? colors.accent : colors.textSecondary)
                                    .frame(width: cardW * 0.4, height: barH * 0.8)
                                    .padding(w * 0.025)
                            }
                    }
                }
                // Faux text lines.
                Capsule().fill(colors.textPrimary).frame(width: contentW * 0.62, height: barH)
                Capsule().fill(colors.textSecondary).frame(width: contentW * 0.44, height: barH)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(
                LinearGradient(colors: [colors.bgTop, colors.bgBottom], startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

/// The per-theme preview graphic. Light/Dark/OLED show their own fixed look;
/// System is one UI split light | dark down the middle (so the centre poster
/// card straddles the seam) to signal "follows your device." Fills whatever
/// frame the caller gives it, so it scales for both the full onboarding card
/// and the compact Settings card.
public struct ThemeSwatch: View {
    private let theme: AppTheme
    private let cornerRadius: CGFloat

    public init(theme: AppTheme, cornerRadius: CGFloat = 16) {
        self.theme = theme
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            switch theme {
            case .system:
                // Both layers render the IDENTICAL full-width layout, then each is
                // masked to its half so every element lines up exactly across the
                // split. The light layer overruns the seam by 0.5pt (and sits under
                // the dark layer) to avoid a hairline gap.
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        )
    }
}

/// Focus + selection chrome for a theme card, mirroring `FocusableSettingsPanel`
/// (Settings' About panel) and the profile tiles: a resting hairline border, an
/// accent wash + ring when selected, and on focus a soft accent outline blooming
/// around the whole card plus a gentle shadow + lift — never the inverted/filled
/// tvOS focus background.
///
/// Implemented as a `ButtonStyle` reading `\.isFocused` (rather than a `.plain`
/// button with a manual overlay) so the system focus fill never draws. The accent
/// is passed in — not read from `\.themePalette` — because that custom environment
/// value doesn't reliably reach a `fullScreenCover`. The card's size/padding comes
/// from the label, so this style is scale-agnostic.
public struct ThemeCardButtonStyle: ButtonStyle {
    let accent: Color
    let isSelected: Bool
    let cornerRadius: CGFloat

    public init(accent: Color, isSelected: Bool, cornerRadius: CGFloat = 28) {
        self.accent = accent
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        ThemeCardButtonBody(configuration: configuration, accent: accent, isSelected: isSelected, cornerRadius: cornerRadius)
    }
}

private struct ThemeCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        // Accent wash marks the ACTIVE theme so selection reads
                        // at a glance, even when another card is focused.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(accent.opacity(isSelected ? 0.22 : 0))
                    )
            )
            // Resting border: a soft accent ring when selected, else a hairline.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.7) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // Focus outline (accent), shown only when focused.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent, lineWidth: 4)
                    .opacity(isFocused ? 1 : 0)
            )
            .shadow(color: .black.opacity(isFocused ? 0.28 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 6 : 0)
            .scaleEffect(isFocused ? 1.01 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

/// A selectable theme card: a preview swatch above the theme name (plus a short
/// description in the full variant). Used both by the onboarding theme picker
/// (`compact: false`, a fixed-width card) and Settings ▸ Appearance
/// (`compact: true`, a smaller, flexible-width card that shares available space).
///
/// The caller owns focus (apply `.focused(...)`) and selection state; tapping
/// invokes `action`.
public struct ThemeOptionCard: View {
    private let theme: AppTheme
    private let isSelected: Bool
    private let accent: Color
    private let compact: Bool
    private let action: () -> Void

    public init(
        theme: AppTheme,
        isSelected: Bool,
        accent: Color,
        compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.theme = theme
        self.isSelected = isSelected
        self.accent = accent
        self.compact = compact
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 10 : 18) {
                ThemeSwatch(theme: theme, cornerRadius: compact ? 10 : 16)
                    .frame(height: compact ? 84 : 160)

                VStack(spacing: compact ? 2 : 6) {
                    HStack(spacing: 6) {
                        Text(theme.displayName)
                            .font(compact ? .headline : .title3.weight(.semibold))
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(compact ? .subheadline : .headline)
                                .foregroundStyle(accent)
                        }
                    }
                    if !compact {
                        Text(theme.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
                    }
                }
            }
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(width: compact ? nil : 320)
            .padding(compact ? 14 : 20)
        }
        .buttonStyle(ThemeCardButtonStyle(
            accent: accent,
            isSelected: isSelected,
            cornerRadius: compact ? 18 : PlozzTheme.Metrics.mediumCardCornerRadius
        ))
        .focusEffectDisabled()
    }
}
#endif
