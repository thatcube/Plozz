#if canImport(SwiftUI)
import SwiftUI

public struct SettingsListRowSurface: ViewModifier {
    @Environment(\.themePalette) private var palette

    public init() {}

    public func body(content: Content) -> some View {
        content.listRowBackground(palette.cardOpaqueSurface)
    }
}

public extension View {
    func settingsListRowSurface() -> some View {
        modifier(SettingsListRowSurface())
    }
}
#endif
