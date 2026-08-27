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

/// Smoothly feathers both vertical edges while leaving horizontal overflow alone.
///
/// For a list that scrolls between fixed chrome — the navigation rail's library
/// list, which sits under a section label and above the pinned Settings row.
/// Clipping alone would cut a row mid-glyph at each end; this dissolves it
/// instead, so nothing ever appears to overlap the chrome.
///
/// `horizontalOverhang` widens the mask left and right so a focused row's own
/// lift and shadow are not clipped by it.
public struct VerticalEdgeFadeMask: View {
    private let topFade: CGFloat
    private let bottomFade: CGFloat
    private let horizontalOverhang: CGFloat

    /// Feathers both ends by the same amount.
    public init(fadeHeight: CGFloat, horizontalOverhang: CGFloat = 0) {
        self.init(
            topFade: fadeHeight,
            bottomFade: fadeHeight,
            horizontalOverhang: horizontalOverhang
        )
    }

    /// Feathers each end independently. A fade of `0` leaves that end hard, which
    /// is what a list wants at an end it is not scrolled past — an always-on fade
    /// dims the first or last row for no reason.
    public init(topFade: CGFloat, bottomFade: CGFloat, horizontalOverhang: CGFloat = 0) {
        self.topFade = topFade
        self.bottomFade = bottomFade
        self.horizontalOverhang = horizontalOverhang
    }

    public var body: some View {
        VStack(spacing: 0) {
            if topFade > 0 {
                edgeFade(reversed: false).frame(height: topFade)
            }
            Color.black
            if bottomFade > 0 {
                edgeFade(reversed: true).frame(height: bottomFade)
            }
        }
        .padding(.horizontal, -horizontalOverhang)
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
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

public extension View {
    /// Feathers the top and bottom edges. `horizontalOverhang` expands the mask
    /// left and right so a focused row's lift and shadow are not clipped by it.
    func verticalEdgeFadeMask(
        fadeHeight: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            VerticalEdgeFadeMask(
                fadeHeight: fadeHeight,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

    /// Feathers each end independently, so a list only dissolves at an end it is
    /// actually scrolled past.
    func verticalEdgeFadeMask(
        topFade: CGFloat,
        bottomFade: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            VerticalEdgeFadeMask(
                topFade: topFade,
                bottomFade: bottomFade,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

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
