#if canImport(SwiftUI)
import SwiftUI

/// The app's call-to-action button: a themed pill for the "Continue" / "Save" /
/// "Retry" affordances that end a form or a setup step.
///
/// This exists because `.buttonStyle(.borderedProminent)` cannot be used here.
/// Plozz ships **no accent colour asset** on purpose — `AccentColor.colorset` is
/// empty, so `Color.accentColor` resolves to whatever each platform defaults to,
/// and the interface is kept monochrome through ``ThemePalette/accent`` instead
/// (see ``ThemePalette/brandAccent(isLight:)``). A prominent button fills itself
/// with the tint and then draws its label white regardless of what that fill
/// turned out to be, so on a dark theme it renders white-on-white: a legible
/// pill shape with an invisible label. Brandon hit exactly that on three pages of
/// profile creation.
///
/// The fix is not a bigger tint. A filled control has to pick its label from the
/// same palette that chose its fill, which is what ``ThemePalette/onAccent``
/// exists for, and no stock style can do that.
public struct PlozzActionButtonStyle: ButtonStyle {
    public enum Role {
        /// The step's affirmative action. Accent fill, inverse label.
        case primary
        /// The way out — "Not Now", "Cancel". Surface fill, ordinary label.
        case secondary
    }

    private let role: Role

    public init(role: Role = .primary) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        ActionPill(configuration: configuration, role: role)
    }

    /// Named to avoid colliding with `ButtonStyle`'s own `Body`
    /// associated type, which a nested `Body` silently satisfies instead.
    private struct ActionPill: View {
        let configuration: ButtonStyle.Configuration
        let role: Role

        @Environment(\.themePalette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        /// tvOS focus wins over role: the platform convention is a bright fill
        /// and a dark glyph on the focused control, and a primary button that
        /// kept its accent fill while focused would be the only control on the
        /// screen not following it.
        private var fill: Color {
            if isFocused { return .white }
            switch role {
            case .primary: return palette.accent
            case .secondary: return palette.cardSurface
            }
        }

        private var foreground: Color {
            if isFocused { return .black }
            switch role {
            case .primary: return palette.onAccent
            case .secondary: return palette.primaryText
            }
        }

        private var border: Color {
            if isFocused || role == .primary { return .clear }
            return palette.cardBorder
        }

        var body: some View {
            configuration.label
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .foregroundStyle(foreground)
                .background(fill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
                // Dimming the whole pill — not just the label — so a disabled
                // primary reads as unavailable rather than as a filled button
                // whose text happens to be faint.
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

public extension View {
    /// Themed call-to-action styling. Use instead of `.borderedProminent` /
    /// `.bordered`, which cannot see the palette — see ``PlozzActionButtonStyle``.
    func plozzActionButton(role: PlozzActionButtonStyle.Role = .primary) -> some View {
        buttonStyle(PlozzActionButtonStyle(role: role))
    }
}
#endif
