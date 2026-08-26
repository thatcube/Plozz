#if canImport(SwiftUI)
import SwiftUI

/// A single line of card caption that **fades** at the edges instead of
/// truncating with an ellipsis, and scrolls its overflow into view while its card
/// holds focus.
///
/// The geometry is borrowed rather than invented. A caption already sits inset
/// from the card's edges — that inset is what keeps text clear of the rounded
/// corners (see `PlozzMetrics.posterCaptionInset`) — so the marquee uses that
/// same gap as its fade zone and the card's own edges as the hard cut-off. Text
/// that runs long doesn't stop short with a "…"; it carries on into the gap,
/// dissolving as it goes, and is completely gone by the card's edge.
///
/// At rest the line sits exactly where it always did: same position, same
/// left-hand start. The only difference is what happens at the far end — a fade
/// where there used to be an ellipsis. Focus is what sets it moving.
///
/// ## Why the mask is constant
///
/// The fade is defined in the *container's* coordinates — clear at the edge,
/// solid `inset` points in — and never changes. The text slides underneath it.
/// That matters for more than tidiness: a gradient computed from the scroll
/// position would have to be rebuilt on every frame of the scroll, which means
/// re-evaluating this view sixty times a second. A fixed mask lets the movement
/// be a pure transform, which animates without the body running at all.
///
/// It also costs nothing for the common case: a caption that fits is never
/// masked, because there is nothing to fade.
public struct PlozzMarqueeText: View {
    private let text: Text
    private let font: Font
    private let color: Color
    private let inset: CGFloat
    private let isFocused: Bool

    /// Intrinsic width of the line. Changes when the text does, not when the card
    /// moves, so observing it is cheap.
    @State private var textWidth: CGFloat = 0
    /// Width available to the caption — the card's content width.
    @State private var containerWidth: CGFloat = 0
    /// How far the line is currently scrolled from its resting position.
    @State private var scroll: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: Text,
        font: Font,
        color: Color,
        inset: CGFloat,
        isFocused: Bool
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.inset = inset
        self.isFocused = isFocused
    }

    /// How far the line runs past the point where the trailing fade begins — and
    /// therefore exactly how far it has to travel to show its end.
    private var overflow: CGFloat {
        guard containerWidth > 0 else { return 0 }
        return max(0, textWidth - (containerWidth - inset * 2))
    }

    private var fades: Bool { overflow > 0.5 }

    public var body: some View {
        text
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            // Lay the line out at its full width instead of truncating it. What
            // runs past the card is clipped, and faded before it gets there.
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textWidth = width
            }
            .offset(x: inset - scroll)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
            .modifier(EdgeFade(inset: inset, width: containerWidth, isEnabled: fades))
            .clipped()
            .onChange(of: isFocused) { _, focused in
                focused ? startScrolling() : returnToRest()
            }
            .onChange(of: overflow) { _, _ in
                // The text itself changed (a recycled card in a lazy row, or a
                // title arriving late). Re-run whichever state we're in.
                isFocused ? startScrolling() : returnToRest()
            }
    }

    /// Walks the line along until its end clears the fade, then back, for as long
    /// as the card holds focus.
    ///
    /// Eased rather than linear on purpose: the slow-down at each end reads as the
    /// line pausing to be read, which is the point of moving it at all, and it
    /// costs nothing over a constant-speed scroll.
    private func startScrolling() {
        let distance = overflow
        guard isFocused, distance > 0.5, !reduceMotion else {
            returnToRest()
            return
        }
        let duration = Double(distance) / PlozzTheme.Metrics.marqueePointsPerSecond
        withAnimation(
            .easeInOut(duration: duration)
                .delay(PlozzTheme.Metrics.marqueeStartDelay)
                .repeatForever(autoreverses: true)
        ) {
            scroll = distance
        }
    }

    /// Hands the line back to its resting position — and, by assigning a
    /// non-repeating animation to the same value, ends the marquee.
    private func returnToRest() {
        withAnimation(.easeOut(duration: 0.25)) {
            scroll = 0
        }
    }
}

/// Dissolves the caption into the gap either side of it: transparent at the
/// card's edge, solid `inset` points in.
///
/// Applied **only** to a line long enough to reach the fade, so a caption that
/// fits — the common case — pays nothing for the mask at all.
private struct EdgeFade: ViewModifier {
    let inset: CGFloat
    let width: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled, width > 0, inset > 0 {
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: leadingEdge),
                        .init(color: .black, location: trailingEdge),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            content
        }
    }

    /// Clamped so the two ramps can never cross on a very narrow card, which
    /// would put the gradient's stops out of order.
    private var leadingEdge: CGFloat { min(inset / width, 0.45) }
    private var trailingEdge: CGFloat { max(1 - inset / width, 0.55) }
}
#endif
