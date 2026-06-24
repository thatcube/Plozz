#if canImport(SwiftUI)
import SwiftUI

/// Size variant for the unified Settings row focus style. `.standard` is the
/// top-level row height; `.prominent` is the taller server-list row that
/// carries an "In use" badge and needs a larger corner radius / shadow.
enum SettingsRowSize {
    case standard
    case prominent
}

/// Single shared, theme-aware focus style for every Settings drill-in row.
///
/// FOCUSED state is the native tvOS "inverted card":
/// - Dark mode focus: WHITE fill, BLACK foreground.
/// - Light mode focus: BLACK fill, WHITE foreground.
/// UNFOCUSED state is transparent and inherits normal foreground colors.
///
/// Subtle scale (1.04) + soft drop shadow + continuous rounded corners give
/// the same native lift Apple TV uses; small enough that — paired with the
/// 10pt inter-row spacing in `profileOwnedRows` — it never bleeds into
/// adjacent rows.
///
/// To keep ALL row content focus + theme adaptive (not just the background)
/// the style propagates the focused state via the environment. Helpers like
/// `.settingsRowSecondary()`, `.settingsRowIcon()`, and
/// `.settingsRowGreenIndicator()` let row content read that and flip their
/// own colors uniformly without re-implementing the logic per row.
struct SettingsFocusButtonStyle: ButtonStyle {
    var size: SettingsRowSize = .standard

    func makeBody(configuration: Configuration) -> some View {
        SettingsFocusBody(configuration: configuration, size: size)
    }
}

private struct SettingsFocusBody: View {
    let configuration: ButtonStyle.Configuration
    let size: SettingsRowSize
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    private var corner: CGFloat { size == .prominent ? 18 : 14 }

    private var focusFill: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    private var focusForeground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    var body: some View {
        configuration.label
            // Inject the focused state + the "what color should focused
            // content be?" into the environment so descendants (subtitle,
            // chevron, icon, green chip…) can adapt without each row
            // reimplementing the logic.
            .environment(\.settingsRowIsFocused, isFocused)
            .environment(\.settingsRowFocusForeground, focusForeground)
            // The HIGHLIGHT grows on focus, NOT the content. The card
            // background extends slightly OUTWARD via a negative padding
            // so text/icons stay anchored in place — only the colored
            // surface and its shadow expand. (Old scaleEffect on the
            // whole label scaled the text too, which read as "weird"
            // because the label visibly grew.)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(isFocused ? focusFill : Color.clear)
                    .padding(.horizontal, isFocused ? -10 : 0)
                    .padding(.vertical, isFocused ? -6 : 0)
                    .shadow(
                        color: Color.black.opacity(isFocused ? 0.30 : 0),
                        radius: isFocused ? 14 : 0,
                        y: isFocused ? 6 : 0
                    )
            )
            // Primary foreground inverts on focus so untouched titles flip.
            // Explicit `.foregroundStyle(...)` on individual leaves (chips,
            // checkmarks) still wins.
            .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground) : AnyShapeStyle(.primary))
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

// MARK: - Focus-aware environment values

private struct SettingsRowIsFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct SettingsRowFocusForegroundKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

extension EnvironmentValues {
    var settingsRowIsFocused: Bool {
        get { self[SettingsRowIsFocusedKey.self] }
        set { self[SettingsRowIsFocusedKey.self] = newValue }
    }
    var settingsRowFocusForeground: Color {
        get { self[SettingsRowFocusForegroundKey.self] }
        set { self[SettingsRowFocusForegroundKey.self] = newValue }
    }
}

// MARK: - Adaptive helpers used by row content

/// Secondary text (trailing value, subtitles, chevrons). On a focused
/// inverted card, inherits the focus foreground at a reduced opacity so it
/// still reads as "secondary" against the inverted fill instead of being
/// invisible (white-on-white) or low-contrast.
struct SettingsRowSecondaryStyle: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.settingsRowFocusForeground) private var focusFg
    func body(content: Content) -> some View {
        content.foregroundStyle(
            focused
            ? AnyShapeStyle(focusFg.opacity(0.72))
            : AnyShapeStyle(.secondary)
        )
    }
}

/// Leading icon: tinted with the app accent when the row is idle, flipped
/// to the focus foreground (black in dark mode focus, white in light mode
/// focus) when focused — so a blue-on-white "blob" can't happen.
struct SettingsRowIconStyle: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.settingsRowFocusForeground) private var focusFg
    func body(content: Content) -> some View {
        content.foregroundStyle(
            focused
            ? AnyShapeStyle(focusFg)
            : AnyShapeStyle(.tint)
        )
    }
}

/// "In use" / status green indicator with a contrast-correct variant on
/// focus: darker green on the white focus card (dark mode), lighter green on
/// the black focus card (light mode), so it stays legible against the
/// inverted fill instead of disappearing into it.
struct SettingsRowGreenIndicatorStyle: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let tint: Color = {
            guard focused else { return .green }
            return colorScheme == .dark
                ? Color(red: 0.10, green: 0.50, blue: 0.22)  // darker on white card
                : Color(red: 0.55, green: 0.95, blue: 0.65)  // lighter on black card
        }()
        return content.foregroundStyle(tint)
    }
}

extension View {
    func settingsRowSecondary() -> some View { modifier(SettingsRowSecondaryStyle()) }
    func settingsRowIcon() -> some View { modifier(SettingsRowIconStyle()) }
    func settingsRowGreenIndicator() -> some View { modifier(SettingsRowGreenIndicatorStyle()) }
}
#endif
