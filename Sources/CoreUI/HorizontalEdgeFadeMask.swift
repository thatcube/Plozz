#if canImport(SwiftUI)
import SwiftUI

/// Smoothly feathers both horizontal edges while leaving vertical overflow alone.
///
/// Shared by cast-credit rails and compact selection rails. The 24-stop
/// smoothstep curve has zero slope at both ends, avoiding the visible crease and
/// banding of a two-stop linear gradient.
public struct HorizontalEdgeFadeMask: View {
    private let fadeWidth: CGFloat
    private let verticalOverhang: CGFloat

    public init(fadeWidth: CGFloat, verticalOverhang: CGFloat = 0) {
        self.fadeWidth = fadeWidth
        self.verticalOverhang = verticalOverhang
    }

    public var body: some View {
        HStack(spacing: 0) {
            edgeFade(reversed: false).frame(width: fadeWidth)
            Color.black
            edgeFade(reversed: true).frame(width: fadeWidth)
        }
        .padding(.vertical, -verticalOverhang)
    }

    private func edgeFade(reversed: Bool) -> some View {
        let samples = 24
        let stops = (0 ... samples).map { step -> Gradient.Stop in
            let t = Double(step) / Double(samples)
            let eased = t * t * (3 - 2 * t)
            return Gradient.Stop(
                color: .black.opacity(reversed ? 1 - eased : eased),
                location: t
            )
        }
        return LinearGradient(
            stops: stops,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// Feathers only the LEADING edge, leaving the trailing edge hard.
///
/// For a rail that scrolls out under fixed chrome (the navigation rail): content
/// has to dissolve on the side it disappears, while the other side keeps the
/// ordinary edge so nothing looks washed out for no reason.
public struct LeadingEdgeFadeMask: View {
    private let fadeWidth: CGFloat
    private let verticalOverhang: CGFloat

    public init(fadeWidth: CGFloat, verticalOverhang: CGFloat = 0) {
        self.fadeWidth = fadeWidth
        self.verticalOverhang = verticalOverhang
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Same 24-stop smoothstep as `HorizontalEdgeFadeMask` — a two-stop
            // linear gradient shows a visible crease and bands on a TV panel.
            LinearGradient(
                stops: (0 ... 24).map { step in
                    let t = Double(step) / 24
                    return Gradient.Stop(color: .black.opacity(t * t * (3 - 2 * t)), location: t)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            Color.black
        }
        .padding(.vertical, -verticalOverhang)
    }
}

public extension View {
    /// Feathers the leading edge only. `verticalOverhang` expands the mask above
    /// and below so a focused card's lift and shadow are not clipped by it.
    func leadingEdgeFadeMask(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            LeadingEdgeFadeMask(
                fadeWidth: fadeWidth,
                verticalOverhang: verticalOverhang
            )
        }
    }

    func horizontalEdgeFadeMask(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            HorizontalEdgeFadeMask(
                fadeWidth: fadeWidth,
                verticalOverhang: verticalOverhang
            )
        }
    }
}
#endif
