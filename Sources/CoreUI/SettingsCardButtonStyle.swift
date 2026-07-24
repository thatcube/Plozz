#if canImport(SwiftUI)
import SwiftUI

/// Button style for large tappable **cards** (e.g. the add-account provider
/// tiles) that matches the shared read-only-card Liquid Glass lift.
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
    private var corner: CGFloat { PlozzTheme.Metrics.mediumCardCornerRadius }

    var body: some View {
        configuration.label
            .plozzGlassCard(cornerRadius: corner, isFocused: isFocused)
            .shadow(color: .black.opacity(isFocused ? 0.30 : 0), radius: 18, y: 9)
            .scaleEffect(isFocused ? 1.025 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif
