#if canImport(SwiftUI)
import SwiftUI

/// Button style for large tappable **cards** (e.g. the add-account provider
/// tiles) that matches the focus treatment of the read-only Settings cards
/// (About, Report a Problem): a resting `.ultraThinMaterial` panel that, on
/// focus, blooms a theme-accent outline and lifts slightly — no stark
/// contrast inversion, no content scaling beyond a gentle 1.01.
///
/// Lives in CoreUI so surfaces outside FeatureSettings (which owns the
/// equivalent `FocusableSettingsPanel`) can adopt the identical look.
public struct SettingsCardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SettingsCardButtonBody(configuration: configuration)
    }
}

private struct SettingsCardButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    private var corner: CGFloat { PlozzTheme.Metrics.mediumCardCornerRadius }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        isFocused ? palette.accent : Color.primary.opacity(0.08),
                        lineWidth: isFocused ? 4 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(
                color: .black.opacity(isFocused ? 0.28 : 0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .scaleEffect(isFocused ? 1.01 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}
#endif
