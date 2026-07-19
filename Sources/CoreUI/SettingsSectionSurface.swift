#if canImport(SwiftUI)
import SwiftUI

public struct SettingsSectionSurface: ViewModifier {
    @Environment(\.themePalette) private var palette

    public init() {}

    public func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.cardOpaqueBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

public extension View {
    func settingsSectionSurface() -> some View {
        modifier(SettingsSectionSurface())
    }
}
#endif
