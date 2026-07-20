#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Nests media content inside the shared framed-card surface using one
    /// concentric rule on every platform: outer radius = inner radius + inset.
    func plozzFramedMediaCard(
        innerCornerRadius: CGFloat,
        isFocused: Bool = false,
        glassAtRest: Bool = true
    ) -> some View {
        modifier(
            ConcentricMediaCardSurface(
                innerCornerRadius: innerCornerRadius,
                isFocused: isFocused,
                glassAtRest: glassAtRest
            )
        )
    }
}

private struct ConcentricMediaCardSurface: ViewModifier {
    @Environment(\.plozzMetrics) private var metrics
    let innerCornerRadius: CGFloat
    let isFocused: Bool
    let glassAtRest: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.cardInset)
            .plozzGlassCard(
                cornerRadius: innerCornerRadius + metrics.cardInset,
                isFocused: isFocused,
                glassAtRest: glassAtRest
            )
    }
}
#endif
