#if canImport(SwiftUI)
import SwiftUI

public struct SettingsPageBackground: View {
    @Environment(\.themePalette) private var palette

    public init() {}

    public var body: some View {
        palette.settingsBackground
            .ignoresSafeArea()
    }
}

private struct SettingsGroupSurface: ViewModifier {
    @Environment(\.themePalette) private var palette
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                palette.elevatedSurface,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
    }
}

public extension View {
    func settingsGroupSurface(cornerRadius: CGFloat) -> some View {
        modifier(SettingsGroupSurface(cornerRadius: cornerRadius))
    }
}
#endif
