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
///
/// ## What this costs, per card (keep it this way)
///
/// A poster wall is dozens of cards and one of them has focus, so the rule for
/// everything here is: **at rest it must cost nothing.** As it stands, a resting
/// card pays for an identity transform and nothing else; a focused card pays for
/// two gradient fills, a shadow, and one position observation:
///
/// - **Nothing is built for an unfocused card.** The sheen, the focus shadow and
///   the position tracking all live inside `if isFocused`, following the rule the
///   halo learned the hard way — a focus surface hidden with `.opacity(0)` still
///   renders, and a row of them measured ~100 offscreen passes a frame on an A12.
///
///   ⚠️ That rule has a hard limit, and `PlozzMarqueeText.EdgeFade` documents
///   where it is: anything **inside a subtree the focus animation animates** must
///   differ between focused and unfocused by its *values*, not by its existence.
///   A modifier that appears on focus is a structural change, and SwiftUI
///   rebuilds the subtree instead of animating it — which turned the caption's
///   slide into a snap. Build-only-when-focused belongs on things drawn *over* or
///   *behind* the card, not on modifiers wrapping content that moves.
/// - **Global position is tracked only while focused.** A global frame is
///   recomputed every time the rail moves, so tracking it on every card meant
///   dozens of cards doing that on every frame of a scroll for the benefit of the
///   one with focus.
/// - **Size is measured only where it changes the answer** — a framed card's
///   growth doesn't depend on it (`measuresSize`), so it isn't measured.
/// - **The lean's transform is fully identity at rest** — real axis, zero angle,
///   zero perspective — and is applied *unconditionally*, because a modifier that
///   comes and goes changes the card's identity and throws away its subtree.
/// - **Geometry is observed, not published.** Size goes to `@State` but only
///   changes on layout; position goes to a reference box, because it changes on
///   every frame of a scroll and putting that in `@State` would re-render the
///   card sixty times a second for a value nothing draws.
/// - **No blend modes, no `drawingGroup`, no live glass.** The sheen is plain
///   alpha. And the highlight style is in fact *lighter* than the outlined one:
///   the focused card gets no `.glassEffect` lift and no glass halo, which is
///   the most expensive thing a focused card can do here.
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
    ///   - outlineReach: how far this card's outline extends **past its own
    ///     bounds** on each edge — the halo's padding for an artwork-only card,
    ///     which blooms outside the artwork. Defaults to `0`, which is right for
    ///     a card that draws its own frame: that frame lives *inside* the card's
    ///     footprint, so nothing is lost when it stops lighting up and there is
    ///     no lost ground to grow back.
    func plozzCardFocusLift(
        isFocused: Bool,
        cornerRadius: CGFloat,
        outlineScale: CGFloat,
        outlineReach: CGFloat = 0
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
    let outlineReach: CGFloat

    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's own layout size, needed to work out how much growth replaces
    /// the outline. Measured only when it is actually used — see `measuresSize`.
    @State private var measuredSize: CGSize = .zero
    /// Where this card is on screen. A reference box rather than `@State`
    /// **on purpose**: it is written on every frame of a scrolling rail, and
    /// putting that in `@State` would invalidate the view sixty times a second
    /// for a value nothing draws.
    @State private var framing = CardFraming()
    /// Which way focus was travelling when it arrived here. Set the moment the
    /// card takes focus and then animated back to zero, so the card rocks once
    /// and settles flat.
    @State private var lean: CGVector = .zero
    /// Whether this focus session has already taken its lean, so the continuous
    /// position reports that follow don't re-trigger it.
    @State private var hasLeaned = false
    /// Bumped each time a lean is set, to drive the unwind. The unwind can't
    /// happen in the same breath as the tilt: two writes to `lean` in one turn
    /// coalesce into a single update, the card renders only the final value, and
    /// the tilt is never seen. Changing this identifier hands the unwind to a
    /// `task`, which runs after the tilt has been committed.
    @State private var arrival = 0

    private var isHighlight: Bool { !focusStyle.drawsFocusOutline }
    private var leansOnArrival: Bool { isHighlight && !reduceMotion }

    /// Whether this card's size is worth measuring.
    ///
    /// Only a card whose outline blooms **outside** it has ground to grow back,
    /// and only that calculation needs the size. A framed card's glass frame is
    /// inside its own bounds, so its reach is zero, its growth is just
    /// `outlineScale`, and measuring it would be work whose answer is discarded —
    /// on every card in the grid.
    private var measuresSize: Bool { isHighlight && outlineReach > 0 }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        guard isHighlight else { return outlineScale }
        return PlozzTheme.Metrics.highlightFocusScale(
            outlineScale: outlineScale,
            contentSize: measuredSize,
            outlineReach: outlineReach
        )
    }

    func body(content: Content) -> some View {
        content
            .modifier(CardSizeReader(isEnabled: measuresSize, size: $measuredSize))
            .background {
                // Position is tracked ONLY while this card holds focus, which is
                // both cheaper and more correct.
                //
                // Cheaper: a global frame has to be recomputed every time the rail
                // moves, so tracking it on every card meant dozens of cards doing
                // that work on every frame of a scroll for the benefit of the one
                // that has focus. One card at a time is nothing.
                //
                // More correct: see `CardFocusMomentum.lastCenter`. The direction
                // is measured from where the previous card *actually was* when it
                // let focus go, which is what these live reports keep current.
                if leansOnArrival && isFocused {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { frame in
                            framing.frame = frame
                            guard !hasLeaned, frame != .zero else { return }
                            hasLeaned = true
                            applyArrivalLean(from: frame)
                        }
                }
            }
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
            .modifier(CardArrivalLean(lean: lean, isEnabled: leansOnArrival))
            .onChange(of: isFocused) { _, focused in
                guard leansOnArrival else { return }
                if focused {
                    hasLeaned = false
                } else {
                    // Hand our final position to whichever card takes focus next,
                    // then land flat: holding a stale direction would make the
                    // next arrival start from the wrong tilt.
                    CardFocusMomentum.shared.depart(from: framing.frame)
                    hasLeaned = false
                    lean = .zero
                }
            }
            .task(id: arrival) { await unwindLean() }
    }

    /// Tips the card as focus lands, in whichever direction focus travelled to
    /// reach it. Nothing is animated here — the lean is the card's *starting*
    /// position, not something to ease into.
    private func applyArrivalLean(from frame: CGRect) {
        guard let travel = CardFocusMomentum.shared.arrive(at: frame) else {
            lean = .zero
            return
        }
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            lean = travel
            arrival &+= 1
        }
    }

    /// Unwinds the tilt on the focus spring, one update after it was applied —
    /// so the card is seen leaning before it rocks back flat.
    private func unwindLean() async {
        guard lean != .zero else { return }
        withAnimation(
            PlozzTheme.Metrics.cardFocusAnimation(
                isFocused: true,
                focusStyle: focusStyle,
                reduceMotion: reduceMotion
            )
        ) {
            lean = .zero
        }
    }
}

/// Holds a card's on-screen frame without publishing it. See `framing`.
private final class CardFraming {
    var frame: CGRect = .zero
}

/// The arrival lean: a card that has just been reached tips away from the
/// direction focus came from — as if the push that moved focus also moved the
/// card — and unwinds flat on the settle spring.
///
/// The rotation axis is perpendicular to the travel, so moving sideways rocks
/// the card about its vertical axis and moving up or down about its horizontal
/// one.
///
/// A resting card is handed a **fully identity** transform — a real axis, a zero
/// angle, and zero perspective. Two reasons, and only the first is cosmetic: a
/// `(0, 0, 0)` axis is a degenerate rotation rather than a harmless identity one,
/// and a projection with perspective is the kind of thing a renderer gives its
/// own layer to. Every card in a grid carries this modifier, and all but one of
/// them are at rest at any moment, so at rest it must cost nothing.
private struct CardArrivalLean: ViewModifier {
    let lean: CGVector
    let isEnabled: Bool

    /// 1 for a straight move, a little more for a diagonal one — the dominant
    /// axis is normalised to ±1 by `CardFocusMomentum`.
    private var magnitude: CGFloat { max(abs(lean.dx), abs(lean.dy)) }

    /// Applied unconditionally, never behind an `if`.
    ///
    /// A modifier that appears and disappears gives the card two different view
    /// identities, and SwiftUI throws away the subtree — artwork included — when
    /// it swaps between them. So a card that isn't leaning gets a real axis, a
    /// zero angle and zero perspective, which is an identity transform: nothing
    /// to project, nothing to composite, and the same view tree either way.
    func body(content: Content) -> some View {
        let leaning = isEnabled && magnitude > 0
        return content.rotation3DEffect(
            .degrees(leaning ? PlozzTheme.Metrics.highlightLeanDegrees * Double(magnitude) : 0),
            axis: leaning ? (x: lean.dy, y: lean.dx, z: 0) : (x: 0, y: 1, z: 0),
            perspective: leaning ? PlozzTheme.Metrics.highlightLeanPerspective : 0
        )
    }
}

/// Reports the view's layout size, but only when something reads it. A
/// `ViewModifier` rather than an inline `if` so the geometry observation is
/// attached or absent for the life of the card, never toggled per frame.
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
            // The steady specular: a card under focus is lit from above. It
            // covers the WHOLE card rather than fading out halfway — a light
            // that stops in the middle reads as a gradient someone drew on the
            // artwork, where an even wash that is simply brighter at the top
            // reads as the card being lit. So the bottom keeps a real value
            // instead of falling to clear.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.20), location: 0),
                        .init(color: .white.opacity(0.12), location: 0.45),
                        .init(color: .white.opacity(0.07), location: 1)
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
        guard animates, !reduceMotion else { return nil }
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
