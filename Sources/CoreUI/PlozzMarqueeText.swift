#if canImport(SwiftUI)
import SwiftUI

/// A single line of card caption that **fades** at the edges instead of
/// truncating with an ellipsis, and walks its overflow into view while its card
/// holds focus.
///
/// The geometry is derived from the card rather than invented. A caption already
/// sits inset from the card's edges — that inset is what keeps text clear of the
/// rounded corners (see `PlozzMetrics.posterCaptionInset`) — and every dimension
/// here is a multiple of it. That is what makes one component fit every card:
/// poster and landscape have different corner radii, framed and borderless
/// different insets again, and all of them move with the display-size setting,
/// so a fade expressed in *card* terms tracks all of it without a table of
/// special cases. Text that runs long doesn't stop short with a "…"; it carries
/// on and dissolves.
///
/// The text sits in a band with the same clearance at both ends — `inset` in
/// from the leading edge, `inset` in from the trailing one — and that band does
/// not move or resize for anything. It had been running to the very edge on the
/// right while the left kept its full inset, which is simply lopsided, and it
/// looked worse still for changing with focus.
///
/// Focus decides exactly one thing here: whether the line walks. It decides
/// nothing about the geometry, which is what keeps a focused caption from
/// drifting sideways while it slides down.
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
/// The fade is defined in the *container's* coordinates and the text slides
/// underneath it, so it changes only when focus does — never while scrolling.
/// That matters for more than tidiness: a gradient computed from the scroll
/// position would have to be rebuilt on every frame of the scroll, which means
/// re-evaluating this view sixty times a second. Holding it still lets the
/// movement be a pure transform, which animates without the body running at all.
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

    /// Where the line begins, and where its leading dissolve finishes.
    private var lead: CGFloat { inset }

    /// Where the line has completely dissolved.
    ///
    /// `inset` short of the caption's trailing edge — the mirror of `lead`, so
    /// the text sits in a band with the same clearance either side. It had been
    /// running to the very edge on the right while the left kept its full inset,
    /// which is simply lopsided, and it looked worse still for changing with
    /// focus.
    private var fadeEnd: CGFloat {
        guard containerWidth > 0 else { return 0 }
        return containerWidth - inset
    }

    /// Where the trailing dissolve begins — and so the last point at which the
    /// text is still at full strength.
    private var fadeStart: CGFloat {
        max(fadeEnd - inset * PlozzTheme.Metrics.marqueeFadeRatio, lead)
    }

    /// How far the line runs past the point where it starts to dissolve — and
    /// therefore exactly how far it has to travel for its end to arrive there at
    /// full strength.
    ///
    /// Every term here is focus-independent, and that is deliberate. Twice now a
    /// measurement that quietly varied with focus has changed whether the line
    /// carries a mask at all, and a mask that appears when a card takes focus is
    /// a structural change inside the subtree the focus animation is animating —
    /// SwiftUI rebuilds rather than animates, and the caption stops sliding. The
    /// fade's geometry is now simply fixed: nothing about it moves when focus
    /// does, so nothing about it can break the animation. Focus decides one
    /// thing, which is whether the line walks.
    private var overflow: CGFloat {
        guard containerWidth > 0 else { return 0 }
        return max(0, textWidth - (fadeStart - lead))
    }

    private var needsFade: Bool { overflow > 0.5 }

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
            // Keyed on overflow ALONE, never on focus. See `EdgeFade`: a mask
            // that appears when a card takes focus is a structural change inside
            // the very subtree the focus animation is animating, and SwiftUI
            // responds by rebuilding it rather than animating it — which snapped
            // the caption into place instead of letting it slide down.
            .modifier(EdgeFade(
                lead: lead,
                fadeStart: fadeStart,
                fadeEnd: fadeEnd,
                width: containerWidth,
                isEnabled: needsFade
            ))
            .clipped()
            .task(id: cycle) { await runMarquee() }
    }

    /// Whether this line should be walking along right now — it has to be the
    /// focused card's, and Reduce Motion has to be off.
    private var isScrolling: Bool { isFocused && !reduceMotion }

    /// The line you actually see: laid out at its full width, offset to its
    /// resting position, and free to run past the card because it is an overlay.
    private var line: some View {
        text
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textWidth = width
            }
            .offset(x: lead - scroll)
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
        // Back to the start INSTANTLY, never as an animation.
        //
        // This runs the moment focus changes, which is the moment the caption is
        // sliding down (or up) — so animating the line back to its start put a
        // sideways slide underneath that, and focusing a card moved its title
        // down and to the right instead of just down. A card recycled by a lazy
        // row carries the same hazard: it can arrive holding the scroll position
        // of whatever title used it last, and would glide out of it in view.
        //
        // Snapping is invisible either way. On the card losing focus the line is
        // dissolving and moving anyway; on the card gaining it the line is where
        // it has always been, so there is nothing to see.
        if scroll != 0 {
            var immediate = Transaction()
            immediate.disablesAnimations = true
            withTransaction(immediate) { scroll = 0 }
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

/// Dissolves the caption at both ends, over distances the caller works out from
/// the card's own geometry.
///
/// ## It is keyed on overflow alone, never on focus (learned the hard way)
///
/// A mask is an offscreen alpha pass, so it is tempting to give one only to the
/// line that is actually moving. That was tried and reverted: the mask then
/// appears at the instant the card takes focus, which is a **structural** change
/// inside the very subtree the focus animation is animating. SwiftUI responds by
/// rebuilding that subtree rather than animating it, so the caption snapped into
/// its focused position instead of sliding down — visible immediately, and only
/// on the long captions, which is what gave it away.
///
/// So the structure is fixed for the life of the card: a line that overflows is
/// masked whether it is moving or not, and a line that fits — the common case —
/// is never masked at all. Only the gradient's *values* would ever change, and
/// they don't: it is defined in the container's coordinates and the text slides
/// underneath it, which is what lets the movement be a pure transform that
/// animates without this view re-evaluating.
///
/// The same rule caught the arrival lean's `rotation3DEffect`
/// (`CardFocusHighlight.CardArrivalLean`). Anything a focused card wears that an
/// unfocused one doesn't must differ by its *values*, not by its existence.
private struct EdgeFade: ViewModifier {
    /// Where the leading dissolve finishes, in points from the caption's leading
    /// edge — which is also where the text begins.
    let lead: CGFloat
    /// Where the trailing dissolve begins and ends, same coordinates.
    let fadeStart: CGFloat
    let fadeEnd: CGFloat
    let width: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled, width > 0 {
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: leadStop),
                        .init(color: .black, location: fadeStartStop),
                        .init(color: .clear, location: fadeEndStop),
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

    // Gradient stops have to be in ascending order or the gradient is undefined,
    // and these are derived from card geometry that a narrow card or a large
    // caption inset can invert. Each one is therefore clamped against the one
    // before it rather than assumed to be in range.
    private var leadStop: CGFloat { clamp(lead / width) }
    private var fadeStartStop: CGFloat { max(clamp(fadeStart / width), leadStop) }
    private var fadeEndStop: CGFloat { max(clamp(fadeEnd / width), fadeStartStop) }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}
#endif
