#if canImport(SwiftUI)
import SwiftUI

/// Fitted, theme-aware focus style for in-player options-menu rows.
///
/// The default tvOS focus effect on a `.plain` button is oversized for these
/// compact rows. This mirrors the Settings drill-in rows instead: on focus the
/// row gets a rounded highlight sized to the row itself (an inverted white card,
/// black foreground) rather than a big system halo. Deliberately *no* drop
/// shadow — a soft shadow forces a per-frame offscreen blur recomposited over
/// the Dolby Vision / HDR video behind the panel, which drops frames on Apple TV
/// (the same problem we removed from the panel container).
///
/// Pair every button using this style with `.focusEffectDisabled()` so the
/// system focus effect doesn't double up with the fitted card.
struct PlayerMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerMenuRowBody(configuration: configuration)
    }
}

private struct PlayerMenuRowBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            // Propagate focus to leaf content (checkmarks, subtitles) so they
            // can flip to legible colors on the inverted white card.
            .environment(\.playerMenuRowIsFocused, isFocused)
            .foregroundStyle(isFocused ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
            .background(
                // Inset the fitted card a hair within the full-width row so it
                // carries an EQUAL, minimal gutter on both sides — wide enough that
                // the highlight reads as covering the row evenly rather than a
                // narrow pill floating off-centre. Text stays anchored by the row's
                // own padding, so titles still line up under the section header.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
                    .padding(.horizontal, 2)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            // Switch color + fill INSTANTLY on focus change. An animated fade
            // lingers as a ghost card when navigating away and, over moving
            // Dolby Vision video, reads as a laggy "fade behind". Instant is
            // both crisper and cheaper (no per-frame animated blend over HDR).
            .animation(nil, value: isFocused)
    }
}

// MARK: - Focus-aware leaf helpers

private struct PlayerMenuRowIsFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var playerMenuRowIsFocused: Bool {
        get { self[PlayerMenuRowIsFocusedKey.self] }
        set { self[PlayerMenuRowIsFocusedKey.self] = newValue }
    }
}

/// Secondary text (row subtitles) — dims to a dark tone on the focused white
/// card so it stays readable instead of vanishing.
private struct PlayerMenuRowSecondaryStyle: ViewModifier {
    @Environment(\.playerMenuRowIsFocused) private var focused
    func body(content: Content) -> some View {
        content.foregroundStyle(focused ? Color.black.opacity(0.6) : Color.secondary)
    }
}

/// Selection mark (checkmark / radio circle). On the focused white card the
/// accent would clash, so selected marks go black and unselected go a dim black;
/// off focus they use the accent / secondary as before.
private struct PlayerMenuRowMarkStyle: ViewModifier {
    let isSelected: Bool
    let accent: Color
    @Environment(\.playerMenuRowIsFocused) private var focused
    func body(content: Content) -> some View {
        let color: Color = {
            if focused { return isSelected ? .black : Color.black.opacity(0.45) }
            return isSelected ? accent : Color.secondary
        }()
        return content.foregroundStyle(color)
    }
}

extension View {
    func playerMenuRowSecondary() -> some View { modifier(PlayerMenuRowSecondaryStyle()) }
    func playerMenuRowMark(isSelected: Bool, accent: Color) -> some View {
        modifier(PlayerMenuRowMarkStyle(isSelected: isSelected, accent: accent))
    }
}
#endif
