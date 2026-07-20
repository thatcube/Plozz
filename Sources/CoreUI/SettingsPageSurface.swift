#if canImport(SwiftUI)
import SwiftUI

public struct SettingsPageSurface: ViewModifier {
    @Environment(\.themePalette) private var palette

    public init() {}

    public func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { AppBackground(palette: palette) }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

public extension View {
    func settingsPageSurface() -> some View {
        modifier(SettingsPageSurface())
    }
}
#endif
