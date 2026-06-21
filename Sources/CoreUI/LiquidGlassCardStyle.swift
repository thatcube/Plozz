#if canImport(SwiftUI)
import SwiftUI

/// Liquid-glass card surface for browsing tiles, ported from the Twozz "Browse"
/// styling so Plozz's library grid matches it. Uses native Liquid Glass on
/// tvOS 26+ and a lightweight translucent fallback on older versions.
public struct PlozzGlassCardModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let isFocused: Bool

    public init(cornerRadius: CGFloat, isFocused: Bool) {
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(tvOS 26.0, *) {
            content
                .glassEffect(
                    isFocused ? .regular.tint(.white.opacity(0.12)) : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .clipShape(shape)
        } else {
            content
                .background {
                    shape.fill(isFocused ? Color.primary.opacity(0.16) : Color.primary.opacity(0.07))
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .clipShape(shape)
        }
    }
}

public extension View {
    /// Wraps the view in the shared Plozz liquid-glass browsing-card surface.
    func plozzGlassCard(cornerRadius: CGFloat, isFocused: Bool) -> some View {
        modifier(PlozzGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

#endif
