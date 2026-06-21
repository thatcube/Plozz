#if canImport(SwiftUI)
import SwiftUI

/// Liquid-glass card surface for browsing tiles, ported from the Twozz "Browse"
/// styling so Plozz's library grid matches it. Uses native Liquid Glass on
/// tvOS 26+ and a lightweight translucent fallback on older versions.
///
/// On focus the surface picks up a **subtle translucent tint** (matching Twozz's
/// focus treatment) — unless the system **Reduce Transparency** accessibility
/// setting is on, in which case it switches to a **solid/opaque** focus fill so
/// the lift stays legible without relying on translucency.
public struct PlozzGlassCardModifier: ViewModifier {
    private let cornerRadius: CGFloat
    private let isFocused: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat, isFocused: Bool) {
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            // Reduce Transparency on: never lean on translucency. Paint a solid
            // surface that turns a touch lighter/opaque on focus.
            content
                .background {
                    shape.fill(isFocused ? Color.plozzOpaqueCardFocused : Color.plozzOpaqueCard)
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? Color.primary.opacity(0.35) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
                }
                .clipShape(shape)
        } else if #available(tvOS 26.0, *) {
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

private extension Color {
    /// Solid card fill used when Reduce Transparency is on (resting state).
    static let plozzOpaqueCard = Color(white: 0.16)
    /// Solid card fill used when Reduce Transparency is on and the card is
    /// focused — a clearly lighter, fully opaque surface.
    static let plozzOpaqueCardFocused = Color(white: 0.26)
}

public extension View {
    /// Wraps the view in the shared Plozz liquid-glass browsing-card surface.
    func plozzGlassCard(cornerRadius: CGFloat, isFocused: Bool) -> some View {
        modifier(PlozzGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

#endif
