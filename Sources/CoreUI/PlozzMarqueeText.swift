#if canImport(SwiftUI)
import SwiftUI

/// A single line of card caption that **fades** at the edges instead of
/// truncating with an ellipsis, and walks its overflow into view while its card
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
/// ## The scrolling line must not be part of the layout
///
/// A line laid out at its full width *is* a wide view, and a wide view widens
/// whatever it sits in — which turned long titles into cards wider than their
/// own artwork. So the card measures a hidden, ordinary, truncating copy, and
/// the real line is drawn as an **overlay** on top of it. An overlay is sized by
/// its host and reports nothing back, so however long the title is, the card
/// stays exactly the width it would have been with a plain `Text`.
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

    /// Restarts the marquee when focus changes, or when a recycled card puts a
    /// different title in this line.
    private var cycle: String { "\(isFocused)-\(Int(overflow.rounded()))" }

    public var body: some View {
        // The layout copy: ordinary, truncating, never drawn. It exists so the
        // card measures a caption that fits, exactly as it did before this line
        // could scroll. Using the real text — rather than a spacer of guessed
        // height — keeps the line's height right in every script.
        text
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { line }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
            // A mask is an offscreen alpha pass, so only the ONE line that is
            // actually moving gets one. Every other overflowing caption in the
            // grid fades through its own text fill instead — see `line`.
            .modifier(EdgeFade(inset: inset, width: containerWidth, isEnabled: fades && isScrolling))
            .clipped()
            .task(id: cycle) { await runMarquee() }
    }

    /// Whether this line is the one being walked along right now.
    ///
    /// Focus is not enough on its own: a focused card whose title fits has
    /// nothing to scroll, and shouldn't be handed a mask for it.
    private var isScrolling: Bool { isFocused && !reduceMotion }

    /// The line you actually see: laid out at its full width, offset to its
    /// resting position, and free to run past the card because it is an overlay.
    private var line: some View {
        text
            .font(font)
            .foregroundStyle(fill)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textWidth = width
            }
            .offset(x: inset - scroll)
    }

    /// How the glyphs are coloured — and, at rest, how a long line dissolves.
    ///
    /// A gradient `foregroundStyle` is painted by the text renderer as it draws
    /// the glyphs. It needs no separate layer and no compositing pass, unlike a
    /// `mask`, which is why it is the right tool for the dozens of resting
    /// captions that merely need a soft end rather than a moving one.
    ///
    /// It can't do the job while the line is moving, though: this gradient is
    /// measured in the *text's* own width, so keeping the fade over the card's
    /// edge as the text slid underneath would mean recomputing it every frame.
    /// That is exactly what the constant container-space mask is for, and only
    /// one line at a time ever needs it.
    private var fill: AnyShapeStyle {
        guard fades, !isScrolling, textWidth > 0 else { return AnyShapeStyle(color) }
        // Where the card's trailing fade sits, expressed as a fraction of the
        // text's own width. The line starts at `inset`, so the card's far edge is
        // `containerWidth - inset` along it, and the fade occupies the last
        // `inset` of that.
        let visible = containerWidth - inset
        let solid = min(max((visible - inset) / textWidth, 0), 1)
        let gone = min(max(visible / textWidth, solid + 0.0001), 1)
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: color, location: 0),
                    .init(color: color, location: solid),
                    .init(color: color.opacity(0), location: gone)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    /// Walks the line out until its end clears the fade, holds it there long
    /// enough to read, glides back, and waits before going again.
    ///
    /// A loop with real pauses rather than a `repeatForever` autoreverse, because
    /// an autoreverse turns around the instant it arrives: the end of the title
    /// is on screen only in passing, and the movement never stops. Holding at
    /// each end is what makes it readable, and what makes it read as a
    /// considered movement rather than something sliding back and forth.
    private func runMarquee() async {
        if scroll != 0 {
            withAnimation(.easeOut(duration: 0.3)) { scroll = 0 }
        }
        let distance = overflow
        guard isScrolling, distance > 0.5 else { return }

        let out = Double(distance) / PlozzTheme.Metrics.marqueePointsPerSecond
        let back = Double(distance) / PlozzTheme.Metrics.marqueeReturnPointsPerSecond
        do {
            try await Task.sleep(for: .seconds(PlozzTheme.Metrics.marqueeStartDelay))
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: out)) { scroll = distance }
                try await Task.sleep(for: .seconds(out + PlozzTheme.Metrics.marqueeEndHold))
                withAnimation(.easeInOut(duration: back)) { scroll = 0 }
                try await Task.sleep(for: .seconds(back + PlozzTheme.Metrics.marqueeRestHold))
            }
        } catch {
            // Cancelled: focus moved on, or the card was recycled. The task that
            // replaces this one puts the line back where it started.
        }
    }
}

/// Dissolves the caption into the gap either side of it: transparent at the
/// card's edge, solid `inset` points in.
///
/// A mask is an offscreen alpha pass, so this is applied **only** to the one
/// line that is actually moving. A caption that fits needs no fade at all, and a
/// long caption sitting still fades through its own text fill instead (see
/// `PlozzMarqueeText.fill`) — which the text renderer paints as it draws the
/// glyphs, with no extra layer.
///
/// The mask earns its cost only while the line moves: it is defined in the
/// *container's* coordinates and never changes, so the text can slide underneath
/// it as a pure transform, without this view re-evaluating on every frame.
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
