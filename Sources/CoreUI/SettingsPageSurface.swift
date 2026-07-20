#if os(iOS) && canImport(SwiftUI)
import SwiftUI

public struct SettingsPageSurface: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 24, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .background { SettingsPageBackground() }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

public extension View {
    func settingsPageSurface() -> some View {
        modifier(SettingsPageSurface())
    }
}
#endif
