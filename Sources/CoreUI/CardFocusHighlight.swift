#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The "Highlight" focus treatment — what a media card does when the focus
/// outline is switched off in Settings ▸ Appearance ▸ Cards.
///
/// tvOS's own idiom for focus is movement and light, not a border: the focused
/// thing grows, catches the light as it arrives, tilts under your finger, and
/// eases back down when it leaves. This file is that treatment, expressed as
/// modifiers every card can adopt without knowing which style is active:
///
/// - ``SwiftUI/View/plozzCardFocusLift(isFocused:cornerRadius:outlineScale:outlineReach:)``
///   replaces a card's `.scaleEffect(isFocused ? scale : 1)`. In the outlined
///   style it *is* that scale effect, unchanged. In the highlight style it grows
///   further — far enough that the card still covers the ground its outline used
///   to (see `PlozzTheme.Metrics.highlightFocusScale`) — and adds the sheen.
/// - ``SwiftUI/View/plozzCardFocusTransition(isFocused:focusedZIndex:animates:)``
///   replaces the `.zIndex` + `.animation` pair that follows it, so the settle
///   curve and the raised z-position are decided in one place.
/// - ``SwiftUI/View/plozzCardFocusParallax(cornerRadius:)`` puts tvOS's real
///   finger-tracking tilt on the card's artwork or surface, and
///   ``SwiftUI/View/plozzSystemFocusEffect()`` is what stops
///   `.focusEffectDisabled()` from suppressing it.
///
/// Cards that draw an outline *around* their artwork rather than lighting their
/// own surface go through `plozzFocusHalo`, which routes to the same lift and
/// parallax.
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

    /// tvOS's own focus parallax: while the card is focused, sliding a finger
    /// across the remote's touch surface tilts it in 3D and slides a specular
    /// highlight over it, tracking the finger.
    ///
    /// This is the system effect, not an imitation — `HoverEffect.highlight` is
    /// documented on tvOS as "a projection effect accompanied with a specular
    /// highlight… motion effects to produce a parallax effect by adjusting the
    /// projection matrix and specular offset". There is no public API to drive
    /// that projection ourselves (`UIMotionEffect` is unavailable on tvOS, and
    /// reading the touch surface directly means taking the remote away from the
    /// focus engine through GameController), so the system effect is both the
    /// best-looking and the only supported route.
    ///
    /// The shape matters: without a matching `hoverEffect` content shape the
    /// specular is clipped to the view's square bounds and lights up the corners
    /// a rounded card doesn't have.
    ///
    /// ⚠️ Anything applying `.focusEffectDisabled()` up the tree **suppresses
    /// this** — that modifier disables hover effects too. Cards gate it through
    /// `plozzSystemFocusEffect`, which keeps it off in the outlined style (where
    /// it exists to kill tvOS's white focus platter) and lets it through here.
    ///
    /// ⚠️ Apply it **inside** the focusable view, not around it: a hover effect
    /// runs when the view carrying it is in the focused hierarchy, so wrapping
    /// the focusable card in it puts the effect on an ancestor that is never
    /// itself focused. In practice that means putting it on the card's artwork or
    /// surface, before `focusableCard`.
    func plozzCardFocusParallax(cornerRadius: CGFloat) -> some View {
        modifier(CardFocusParallaxModifier(cornerRadius: cornerRadius))
    }

    /// Whether tvOS may draw its own focus effect on this card.
    ///
    /// Cards have always switched it off: on a `Button` it paints a stark white
    /// platter behind the card that buries our glass treatment. But
    /// `.focusEffectDisabled()` is a blunt instrument — it disables *hover*
    /// effects as well, which is where the native tilt-and-specular lives. So it
    /// stays on for the outlined style, and steps aside for the highlight style,
    /// whose whole point is to let tvOS do what tvOS does.
    func plozzSystemFocusEffect() -> some View {
        modifier(SystemFocusEffectGate())
    }
}

/// See ``SwiftUI/View/plozzSystemFocusEffect()``.
private struct SystemFocusEffectGate: ViewModifier {
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.focusEffectDisabled(focusStyle.drawsFocusOutline || reduceMotion)
    }
}

/// See ``SwiftUI/View/plozzCardFocusParallax(cornerRadius:)``.
private struct CardFocusParallaxModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reduce Motion takes the tilt out — it is motion, and the point of the
    /// setting is less of it. `SystemFocusEffectGate` agrees, so the effect is
    /// suppressed at both ends rather than left half-on.
    private var isEnabled: Bool { !focusStyle.drawsFocusOutline && !reduceMotion }

    func body(content: Content) -> some View {
        #if os(tvOS)
        if isEnabled {
            content
                // Without a matching hover content shape the specular is clipped
                // to the view's square bounds and lights up corners a rounded
                // card doesn't have.
                .contentShape(
                    .hoverEffect,
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .hoverEffect(.highlight)
        } else {
            content
        }
        #else
        content
        #endif
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
                    CardFocusSheen(
                        cornerRadius: cornerRadius,
                        sweeps: !reduceMotion,
                        // tvOS's own parallax brings a specular that tracks the
                        // remote; a second static one on top of it just dulls the
                        // artwork. Ours is the fallback for when the system
                        // effect isn't running (Reduce Motion).
                        showsSteadySpecular: reduceMotion
                    )
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

/// The arrival "glisten": a band of light that sweeps diagonally across a card
/// once as focus lands on it, and — where tvOS's own parallax isn't running — a
/// steady specular that keeps the focused card looking lit afterwards.
///
/// The sweep earns its place even alongside the system effect. tvOS's specular
/// tracks the remote's touch surface, so it only moves if a finger is on the
/// pad; someone navigating by clicking the ring gets a card that grows but never
/// catches the light. The sweep is what makes focus *arriving* visible either
/// way.
///
/// Deliberately plain alpha rather than a blend mode. An additive/screen blend
/// looks marginally brighter over dark artwork but forces the card into its own
/// offscreen compositing pass, and this app has already paid for that mistake
/// once on a rail of cards (see `FocusHaloModifier`). A white gradient at low
/// opacity reads as light on artwork and costs nothing.
private struct CardFocusSheen: View {
    let cornerRadius: CGFloat
    /// Whether the arrival sweep runs (off under Reduce Motion).
    let sweeps: Bool
    /// Whether to draw our own steady specular, or leave that to tvOS.
    let showsSteadySpecular: Bool

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
            if showsSteadySpecular {
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
            }

            if sweeps {
                shape.fill(sweepGradient)
            }
        }
        .allowsHitTesting(false)
        .task {
            // The overlay only exists while the card holds focus, so appearing
            // *is* the card taking focus — no state to compare against.
            guard sweeps else { return }
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
