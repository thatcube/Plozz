#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The "Highlight" focus treatment — what a media card does when the focus
/// outline is switched off in Settings ▸ Appearance ▸ Cards.
///
/// tvOS's own idiom for focus is movement and light, not a border: the focused
/// thing grows, catches a specular sweep as it arrives, and eases back down when
/// it leaves. This file is that treatment, expressed as two modifiers every card
/// can adopt without knowing which style is active:
///
/// - ``SwiftUI/View/plozzCardFocusLift(isFocused:cornerRadius:outlineScale:outlineReach:)``
///   replaces a card's `.scaleEffect(isFocused ? scale : 1)`. In the outlined
///   style it *is* that scale effect, unchanged. In the highlight style it grows
///   further — far enough that the card still covers the ground its outline used
///   to (see `PlozzTheme.Metrics.highlightFocusScale`) — and adds the sheen.
/// - ``SwiftUI/View/plozzCardFocusTransition(isFocused:focusedZIndex:animates:)``
///   replaces the `.zIndex` + `.animation` pair that follows it, so the settle
///   curve and the raised z-position are decided in one place.
///
/// Cards that draw an outline *around* their artwork rather than lighting their
/// own surface go through `plozzFocusHalo`, which routes to the same lift.
///
/// ## Do NOT reach for tvOS's own focus effect here (tried 2026-08-25, reverted)
///
/// The obvious idea is that the system already does this: SwiftUI's
/// `.hoverEffect(.highlight)` is documented on tvOS as a projection effect with a
/// specular highlight and motion-driven parallax, so a focused card would tilt
/// under a finger moving on the remote's touch surface — the one thing this file
/// can't reproduce. It was implemented (`.contentShape(.hoverEffect, …)` for the
/// shape, with `.focusEffectDisabled()` gated off so it wasn't suppressed) and
/// then removed, because on real cards it brings a whole geometry with it and
/// none of it is separable:
///
/// - **It is clipped to its container.** The tilt can't move outside whatever
///   bounds the card sits in, so in a rail it wiggles inside an invisible box
///   instead of leaning out over its neighbours.
/// - **It adds its own growth**, on top of the card's, and the amount is neither
///   documented nor configurable.
/// - **It squares off round tiles.** A cast/artist avatar gets a square-ish
///   focus plate with a faint outline and the circle sitting inside it, even
///   with a circular hover content shape.
///
/// None of that can be turned off piecemeal: `.highlight` is atomic, there is no
/// shape-taking `hoverEffect` overload on tvOS, `UIHoverStyle`/`UIShape` are not
/// available on tvOS at all, the visionOS `HoverEffectContent` builder (which
/// would expose the effect's phase so we could drive our own transforms) is
/// unavailable here, and `.focusEffectDisabled()` is all-or-nothing. So it is
/// the system's entire focus treatment or none of it — and this app already has
/// its own card geometry (concentric radii, halo, caption push) that the
/// system's disagrees with.
///
/// Nor is there a way to build the tilt by hand: `UIMotionEffect` is unavailable
/// on tvOS, `adjustsImageWhenAncestorFocused` only covers a `UIImageView`'s own
/// image, and reading the touch surface through GameController routes the remote
/// away from the focus engine. **Finger-tracking tilt is therefore off the table
/// for our cards.** What this file does instead — grow, sweep, settle — is
/// driven purely by focus, which is the input we actually have.
public extension View {
    /// The focus lift for a card, in whichever style the profile has chosen.
    ///
    /// - Parameters:
    ///   - isFocused: whether this card currently holds focus.
    ///   - cornerRadius: the card's outer radius, so the sheen is clipped to the
    ///     card's own shape (pass `diameter / 2` for a circular tile).
    ///   - outlineScale: the scale this card uses in the outlined style. Pass `1`
    ///     to ask for no lift at all (Reduce Motion) and neither style will add
    ///     one.
    ///   - outlineReach: how far this card's outline extends past its layout
    ///     bounds on each edge — the halo's padding for artwork-only cards.
    ///     Defaults to the framed card's glass inset, which is what a card that
    ///     lights its own surface grows by.
    func plozzCardFocusLift(
        isFocused: Bool,
        cornerRadius: CGFloat,
        outlineScale: CGFloat,
        outlineReach: CGFloat? = nil
    ) -> some View {
        modifier(CardFocusLiftModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            outlineScale: outlineScale,
            outlineReach: outlineReach
        ))
    }

    /// The z-position and animation curve for a focused card: the settle, and the
    /// raised stacking that lets it finish.
    ///
    /// - Parameters:
    ///   - isFocused: whether this card currently holds focus.
    ///   - focusedZIndex: how far to raise the card above its neighbours.
    ///   - animates: pass `false` to suppress the focus animation entirely
    ///     (cards that already opt out under Reduce Motion).
    func plozzCardFocusTransition(
        isFocused: Bool,
        focusedZIndex: Double = 2,
        animates: Bool = true
    ) -> some View {
        modifier(CardFocusTransitionModifier(
            isFocused: isFocused,
            focusedZIndex: focusedZIndex,
            animates: animates
        ))
    }
}

// MARK: - Lift

private struct CardFocusLiftModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let outlineScale: CGFloat
    let outlineReach: CGFloat?

    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's own layout size, needed to work out how much growth replaces
    /// the outline. Measured only in the highlight style — the outlined style
    /// never reads it, so it never pays for the measurement.
    @State private var measuredSize: CGSize = .zero

    private var isHighlight: Bool { !focusStyle.drawsFocusOutline }

    private var scale: CGFloat {
        guard isHighlight else { return outlineScale }
        return PlozzTheme.Metrics.highlightFocusScale(
            outlineScale: outlineScale,
            contentSize: measuredSize,
            outlineReach: outlineReach ?? metrics.cardInset
        )
    }

    func body(content: Content) -> some View {
        content
            .modifier(CardSizeReader(isEnabled: isHighlight, size: $measuredSize))
            .overlay {
                // Built only while focused, and only in the style that uses it —
                // the same rule the focus halo follows (see `FocusHaloModifier`).
                // One card holds focus at a time, so one card should be the only
                // one drawing a sheen.
                if isHighlight && isFocused {
                    CardFocusSheen(cornerRadius: cornerRadius, animates: !reduceMotion)
                        .transition(.opacity)
                }
            }
            .scaleEffect(isFocused ? scale : 1)
    }
}

/// Reports the view's layout size, but only when the active focus style needs
/// it. A `ViewModifier` rather than an inline `if` so the geometry observation
/// is attached or absent, never toggled per frame.
private struct CardSizeReader: ViewModifier {
    let isEnabled: Bool
    @Binding var size: CGSize

    func body(content: Content) -> some View {
        if isEnabled {
            content.onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
        } else {
            content
        }
    }
}

// MARK: - Sheen

/// The "glisten": a soft specular that sits on the focused card, plus a band of
/// light that sweeps diagonally across it once as focus arrives.
///
/// Deliberately plain alpha rather than a blend mode. An additive/screen blend
/// looks marginally brighter over dark artwork but forces the card into its own
/// offscreen compositing pass, and this app has already paid for that mistake
/// once on a rail of cards (see `FocusHaloModifier`). A white gradient at low
/// opacity reads as light on artwork and costs nothing.
private struct CardFocusSheen: View {
    let cornerRadius: CGFloat
    let animates: Bool

    /// Where the sweeping band sits, in gradient space: below 0 it is off the
    /// leading corner, above 1 it has left the trailing one.
    @State private var sweep: CGFloat = -0.4

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // The steady specular: a card under focus is lit from above, which is
            // what keeps it looking raised once the sweep has passed.
            shape.fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.16),
                        .white.opacity(0.04),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            if animates {
                shape.fill(sweepGradient)
            }
        }
        .allowsHitTesting(false)
        .task {
            // The overlay only exists while the card holds focus, so appearing
            // *is* the card taking focus — no state to compare against.
            guard animates else { return }
            sweep = -0.4
            withAnimation(.easeOut(duration: PlozzTheme.Metrics.highlightSheenDuration)) {
                sweep = 1.4
            }
        }
    }

    private var sweepGradient: LinearGradient {
        // Clamped in ascending order: gradient stops must not run backwards, and
        // the band starts and ends outside the card.
        let lead = min(max(sweep - 0.22, 0), 1)
        let crest = min(max(sweep, 0), 1)
        let trail = min(max(sweep + 0.22, 0), 1)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: lead),
                .init(color: .white.opacity(0.38), location: crest),
                .init(color: .clear, location: trail),
                .init(color: .clear, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Transition

private struct CardFocusTransitionModifier: ViewModifier {
    let isFocused: Bool
    let focusedZIndex: Double
    let animates: Bool

    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True while a card that has just lost focus is still easing back down.
    @State private var isSettling = false
    /// Identifies the current settle, so an older one can't clear a newer one.
    @State private var settleGeneration = 0

    private var isHighlight: Bool { !focusStyle.drawsFocusOutline && !reduceMotion }

    private var animation: Animation? {
        guard animates else { return nil }
        return PlozzTheme.Metrics.cardFocusAnimation(
            isFocused: isFocused,
            focusStyle: focusStyle,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .zIndex(isFocused || isSettling ? focusedZIndex : 0)
            .animation(animation, value: isFocused)
            .modifier(CardSettleTracker(
                isFocused: isFocused,
                // The outlined style's ease is short enough that nothing is ever
                // caught mid-shrink, so it keeps today's plain z-position.
                isEnabled: isHighlight && animates,
                isSettling: $isSettling,
                generation: $settleGeneration
            ))
    }
}

/// Holds a card above its neighbours until its settle has finished.
///
/// Without this the card drops to `zIndex 0` the instant focus moves on, and the
/// card that just took focus — now scaled up and overlapping — draws over the
/// top of it while it is still easing back down. The outlined style never
/// noticed because its ease is over in 0.18s; a settle you can watch has to
/// finish where you can see it.
private struct CardSettleTracker: ViewModifier {
    let isFocused: Bool
    let isEnabled: Bool
    @Binding var isSettling: Bool
    @Binding var generation: Int

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { _, focused in
            // Bump first, so any settle already in flight is superseded whatever
            // happens next.
            let mine = generation &+ 1
            generation = mine
            guard isEnabled, !focused else {
                isSettling = false
                return
            }
            isSettling = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(PlozzTheme.Metrics.highlightSettleDuration))
                guard generation == mine else { return }
                isSettling = false
            }
        }
    }
}
#endif
