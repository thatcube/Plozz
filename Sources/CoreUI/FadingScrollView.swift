#if canImport(SwiftUI)
import SwiftUI

/// A bounded-height vertical scroll area that fades an edge **only when there is
/// more content to scroll toward in that direction** — a top fade appears once
/// you've scrolled down, a bottom fade while more remains below, and neither
/// shows when the content fits or you're parked at that end. It's a directional
/// "keep scrolling" affordance, not a permanent edge vignette.
///
/// Horizontal content is never clipped (`scrollClipDisabled`), so a focused row's
/// tvOS highlight/scale is free to bleed to the container's edge instead of being
/// cut off at the sides; only the vertical extent is bounded, via a render-only
/// mask that also draws the fades. The mask never affects hit-testing or focus.
public struct FadingScrollView<Content: View>: View {
    private let maxHeight: CGFloat
    private let fadeLength: CGFloat
    private let content: Content
    private let space = "FadingScrollView"

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrolled: CGFloat = 0

    /// - Parameters:
    ///   - maxHeight: The tallest the scroll area grows before it scrolls.
    ///     Shorter content lays out at its natural height (no empty filler).
    ///   - fadeLength: The height of each edge's fade band, in points.
    public init(
        maxHeight: CGFloat = 620,
        fadeLength: CGFloat = 34,
        @ViewBuilder content: () -> Content
    ) {
        self.maxHeight = maxHeight
        self.fadeLength = fadeLength
        self.content = content()
    }

    private var overflowing: Bool { contentHeight > viewportHeight + 1 }
    private var showTopFade: Bool { overflowing && scrolled > 2 }
    private var showBottomFade: Bool {
        overflowing && (scrolled + viewportHeight) < (contentHeight - 2)
    }
    private var resolvedHeight: CGFloat {
        contentHeight <= 0 ? maxHeight : min(contentHeight, maxHeight)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // A little vertical breathing room so the first/last row's focus
            // highlight sits inside the frame rather than flush against the fade.
            content
                .padding(.vertical, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollMetricsKey.self,
                            value: ScrollMetrics(
                                offset: -proxy.frame(in: .named(space)).minY,
                                height: proxy.size.height
                            )
                        )
                    }
                )
        }
        .scrollClipDisabled()
        .coordinateSpace(name: space)
        .frame(height: resolvedHeight)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewportHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ScrollMetricsKey.self) { metrics in
            scrolled = max(0, metrics.offset)
            contentHeight = metrics.height
        }
        .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
        .mask(fadeMask)
    }

    private var fadeMask: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let fraction = min(max(fadeLength / height, 0), 0.45)
            LinearGradient(
                stops: maskStops(fraction: fraction),
                startPoint: .top,
                endPoint: .bottom
            )
            // Extend the opaque mask well beyond the horizontal bounds so a
            // focused row's highlight/scale (allowed to overflow via
            // scrollClipDisabled) is never masked at the sides.
            .padding(.horizontal, -400)
        }
    }

    private func maskStops(fraction: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: showTopFade ? .clear : .black, location: 0))
        if showTopFade { stops.append(.init(color: .black, location: fraction)) }
        if showBottomFade { stops.append(.init(color: .black, location: 1 - fraction)) }
        stops.append(.init(color: showBottomFade ? .clear : .black, location: 1))
        return stops
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var height: CGFloat
}

private struct ScrollMetricsKey: PreferenceKey {
    static var defaultValue = ScrollMetrics(offset: 0, height: 0)
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        let next = nextValue()
        if next.height > 0 { value = next }
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
