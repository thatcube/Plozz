#if canImport(SwiftUI)
import SwiftUI

public struct SettingsPageBackground: View {
    @Environment(\.themePalette) private var palette

    public init() {}

    public var body: some View {
        palette.backgroundSecondary
            .ignoresSafeArea()
    }
}

private struct SettingsGroupSurface: ViewModifier {
    @Environment(\.themePalette) private var palette
    @Environment(\.displayScale) private var displayScale
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                palette.cardOpaqueSurface,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    palette.cardOpaqueBorder,
                    lineWidth: 1 / max(displayScale, 1)
                )
                .allowsHitTesting(false)
            }
    }
}

public extension View {
    func settingsGroupSurface(cornerRadius: CGFloat) -> some View {
        modifier(SettingsGroupSurface(cornerRadius: cornerRadius))
    }
}
#endif
