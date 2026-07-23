#if canImport(SwiftUI)
import SwiftUI

/// A menu row that keeps a stable leading selection column so every title
/// starts at the same horizontal position.
public struct MenuSelectionLabel: View {
    private let title: String
    private let isSelected: Bool

    public init(_ title: String, isSelected: Bool) {
        self.title = title
        self.isSelected = isSelected
    }

    public var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark")
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
        }
    }
}
#endif
