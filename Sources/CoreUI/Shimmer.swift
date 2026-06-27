#if canImport(SwiftUI)
import SwiftUI

/// A reusable shimmer overlay for placeholder/skeleton content: a soft highlight
/// sweeps horizontally across the view to signal "loading" without a spinner.
///
/// Accessibility: respects **Reduce Motion** — when set, the sweep is replaced by
/// a static dim so the placeholder still reads as inactive but nothing animates.
private struct ShimmerModifier: ViewModifier {
    var active: Bool
    /// One full sweep duration.
    var duration: Double = 1.25
    /// Highlight strength.
    var intensity: Double = 0.35

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        guard active else { return AnyView(content) }
        if reduceMotion {
            return AnyView(content.opacity(0.65))
        }
        return AnyView(
            content
                .overlay {
                    GeometryReader { geo in
                        let width = geo.size.width
                        LinearGradient(
                            colors: [.clear, .white.opacity(intensity), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // Sweep a band ~60% of the width across and a little past
                        // each edge so the highlight enters and exits cleanly.
                        .frame(width: max(width, 1) * 0.6)
                        .offset(x: phase * max(width, 1) * 1.6)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .mask(content)
                }
                .onAppear {
                    phase = -1
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        )
    }
}

public extension View {
    /// Overlays an animated shimmer used by skeleton placeholders. Pass
    /// `active: false` to disable (e.g. once real content has loaded).
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

#endif
