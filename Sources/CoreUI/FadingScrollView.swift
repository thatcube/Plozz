#if canImport(SwiftUI)
import SwiftUI

/// A bounded-height vertical scroll area that fades its top and bottom edges
/// **only when the content overflows**, giving a consistent "there's more above/
/// below — keep scrolling" affordance across the app (onboarding folder pickers,
/// server lists, long forms).
///
/// The fade is a render-only `mask`, so it never affects hit-testing or tvOS
/// focus: focusable rows inside still receive focus and the scroll view moves the
/// focused row into view as usual. When the content fits, no mask is applied, so
/// short lists render fully crisp with no edge dimming.
public struct FadingScrollView<Content: View>: View {
    private let maxHeight: CGFloat
    private let fadeLength: CGFloat
    private let showsIndicators: Bool
    private let content: Content

    /// - Parameters:
    ///   - maxHeight: The tallest the scroll area grows before it starts
    ///     scrolling. Shorter content lays out at its natural height.
    ///   - fadeLength: The height of each edge's fade band, in points.
    ///   - showsIndicators: Whether to show the scroll indicator.
    public init(
        maxHeight: CGFloat = 640,
        fadeLength: CGFloat = 32,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.maxHeight = maxHeight
        self.fadeLength = fadeLength
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    @State private var contentHeight: CGFloat = 0

    private var isOverflowing: Bool { contentHeight > maxHeight + 1 }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .frame(maxHeight: min(contentHeight == 0 ? maxHeight : contentHeight, maxHeight))
        .onPreferenceChange(ContentHeightPreferenceKey.self) { contentHeight = $0 }
        .mask(fadeMask)
    }

    @ViewBuilder
    private var fadeMask: some View {
        if isOverflowing {
            GeometryReader { proxy in
                let h = max(proxy.size.height, 1)
                // Convert the fixed-point fade band into gradient fractions so the
                // band stays a constant visual size regardless of list height.
                let f = min(max(fadeLength / h, 0), 0.5)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: f),
                        .init(color: .black, location: 1 - f),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            // No overflow → no fade, fully opaque so short lists stay crisp.
            Rectangle()
        }
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
