#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Info / Cast tab strip and the card it expands, as one drop-in view.
///
/// Exists so iPad gets the tvOS card rather than an imitation of it. The panels
/// themselves — `InfoPanelView`, `CastPanelView` — are shared verbatim; only the
/// thing that opens them differs, because a remote and a finger are not the same
/// instrument. tvOS keeps its own copy inside `PlayerControls`, where the strip
/// is entangled with the transport's focus choreography (entry targets, exit
/// guides, tab memory) in ways a touch surface has no use for.
///
/// The panels being reusable at all is the whole point: they were written
/// against `PlayerControlsModel` and a `@FocusState.Binding`, and `@FocusState`
/// compiles on iOS where it simply never engages. That is exactly right for
/// touch — the focused treatment never appears, the resting one always does, and
/// taps drive everything.
@available(tvOS, unavailable, message: "tvOS drives this from PlayerControls, which owns the focus choreography")
public struct PlayerTouchCardStrip: View {
    private let model: PlayerControlsModel
    private let onRestart: () -> Void
    private let onNextEpisode: () -> Void
    private let onPreviousEpisode: () -> Void

    /// Whether a card is open, owned by the HOST.
    ///
    /// The host has to know, because dismissing by tapping above the card is its
    /// job: the tap lands on the video, which this view does not own and must
    /// not cover. Setting it false from out there closes whichever tab was open.
    @Binding private var isCardOpen: Bool
    /// Which tab is open. Private because `PlayerControls.Category` is internal
    /// to this module, and exposing it would drag the transport's whole
    /// vocabulary into the app shells for no benefit.
    @State private var openPanel: PlayerControls.Category?
    /// Required by the shared panels and deliberately inert here: nothing on a
    /// touch surface takes focus, so every control renders in its resting state.
    @FocusState private var focus: PlayerControls.FocusSlot?
    @State private var castDetailPerson: MediaPerson?
    @State private var castCloseRequest = 0
    /// The width the strip has actually been given, which decides the card's
    /// layout. Measured rather than inferred from idiom or size class: an iPad
    /// window can be dragged to any width, and the card has to answer for the
    /// one it got.
    /// The space the player has, which the HOST measures: this view is only as
    /// tall as its own content, so its height says nothing about how much of the
    /// screen a card may take.
    private let availableSize: CGSize

    /// The curve the card opens and closes on, and therefore the curve the tab
    /// row travels on.
    private static let cardCurve: Animation = .easeInOut(duration: 0.24)

    private var metrics: PlayerCardMetrics {
        .resolved(forWidth: availableSize.width, height: availableSize.height)
    }

    public init(
        model: PlayerControlsModel,
        availableSize: CGSize,
        isCardOpen: Binding<Bool>,
        onRestart: @escaping () -> Void,
        onNextEpisode: @escaping () -> Void,
        onPreviousEpisode: @escaping () -> Void
    ) {
        self.model = model
        self.availableSize = availableSize
        self._isCardOpen = isCardOpen
        self.onRestart = onRestart
        self.onNextEpisode = onNextEpisode
        self.onPreviousEpisode = onPreviousEpisode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabRow
            if let openPanel {
                card(for: openPanel)
                    // Grows upward out of the tabs, matching tvOS. The card is
                    // laid out ABOVE its strip in the enclosing bottom-anchored
                    // stack, so a bottom anchor is what makes it read as opening
                    // from the tab rather than dropping onto it.
                    .transition(
                        .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity)
                    )
            }
        }
        // NO `.animation(_:value: openPanel)` here, and that is the fix rather
        // than an omission.
        //
        // The tab row does not move because anything inside this VStack moves. It
        // moves because the VStack gets TALLER and its parent is bottom-anchored,
        // so the parent re-lays it out higher up. A child's `.animation` modifier
        // scopes to that child's own attributes and cannot reach a repositioning
        // performed by its parent — so the row's travel was not animated at all.
        //
        // Both tabs therefore jumped... except the one just tapped, which had a
        // live animation scope of its own (`value: isPressed`) that caught the
        // geometry change and eased it. That is the whole "one tab animates
        // slowly, the other snaps into place" — not two rates, but one animated
        // tab and one unanimated one.
        //
        // `withAnimation` at each mutation opens a GLOBAL transaction instead,
        // which every dependent layout inherits — including the parent's.
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.playerCardMetrics, metrics)
        .environment(\.mediaBadgeScale, metrics.badgeScale)
        // Kept in step both ways: this view decides WHICH tab is open, the host
        // only ever needs to know THAT one is, and to be able to close it.
        .onChange(of: openPanel) { _, panel in
            let open = panel != nil
            if isCardOpen != open { isCardOpen = open }
        }
        .onChange(of: isCardOpen) { _, open in
            // Dismissed from outside — a tap on the video. Same curve as opening,
            // and the same reason for the global transaction.
            if !open, openPanel != nil {
                withAnimation(Self.cardCurve) { openPanel = nil }
            }
        }
    }

    private var tabRow: some View {
        HStack(spacing: 20) {
            tab(.info, title: Text("Info"))
            // Hidden entirely when there is no cast: a tab that opens an empty
            // card is worse than an absent one.
            if !model.infoCard.cast.isEmpty {
                tab(.cast, title: Text(PlayerControls.Category.cast.title))
            }
            Spacer(minLength: 20)
        }
    }

    private func tab(_ category: PlayerControls.Category, title: Text) -> some View {
        Button {
            // Tapping the open tab closes it, so the same control both opens and
            // dismisses — there is no Menu button to fall back on here.
            withAnimation(Self.cardCurve) {
                openPanel = (openPanel == category) ? nil : category
            }
        } label: {
            title
        }
        .buttonStyle(PlayerTabButtonStyle(focused: false, selected: openPanel == category))
        // Makes the whole pill tappable, including its padding.
        //
        // Without it only the glyph-sized label takes the tap and everything
        // around it falls through to the overlay's full-screen dismiss layer —
        // so pressing a tab read as tapping OFF the controls and hid them. The
        // same failure is documented on `playerTransportGlyph` in the iOS
        // overlay; a capsule here because that is the shape the style draws.
        .contentShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private func card(for category: PlayerControls.Category) -> some View {
        Group {
            switch category {
            case .cast:
                CastPanelView(
                    model: model,
                    focus: $focus,
                    detailPerson: $castDetailPerson,
                    closeRequest: $castCloseRequest,
                    isCardOpen: true,
                    revealClock: .easeInOut(duration: 0.24)
                )
            default:
                InfoPanelView(
                    model: model,
                    actions: touchActions,
                    focus: $focus,
                    onClose: { openPanel = nil }
                )
            }
        }
        .modifier(PlayerCardHeight(metrics: metrics))
        // Deliberately NOT clipped to the panel's rounded rectangle.
        //
        // Both panels already draw their own rounded glass, so a clip here buys
        // no corners — but it does re-clip the cast row, which spends effort
        // (`scrollClipDisabled`) escaping exactly this. That row is meant to run
        // past the card's edges so the first and last faces scroll in whole
        // rather than sliced, which is how it behaves on tvOS. Clipping to the
        // card put the slice back and bound the row to the card's width.
    }

    /// Only the three the Info panel actually calls. The rest of
    /// `PlayerOptionsActions` defaults to no-ops, and the touch player reaches
    /// tracks and speed through its own options menu rather than this card.
    private var touchActions: PlayerOptionsActions {
        var actions = PlayerOptionsActions()
        actions.restart = onRestart
        actions.playNextEpisode = onNextEpisode
        actions.playPreviousEpisode = onPreviousEpisode
        return actions
    }
}
#endif

/// The scrub bar for touch, drawn like the tvOS one.
///
/// A hand-built bar rather than a `Slider`, because the stock control brings a
/// grab handle and a fixed track that read as a form field rather than as a
/// timeline. This matches `ScrubBar`: a thin capsule at rest, a thicker one
/// while touched, a slim knob rather than a thumb, and a dimmer fill behind the
/// played portion.
///
/// It grows on touch-down and STAYS grown for the whole drag, which is the tvOS
/// behaviour and also the useful one — a bar that shrinks back the instant you
/// start moving gives up precision exactly when you asked for it.
@available(tvOS, unavailable, message: "tvOS has ScrubBar, which this deliberately mirrors")
public struct PlayerTouchScrubBar: View {
    private let currentSeconds: TimeInterval
    private let duration: TimeInterval
    private let bufferedFraction: Double
    private let onScrub: (TimeInterval) -> Void
    private let onScrubbingChanged: (Bool) -> Void

    @State private var isTouching = false

    /// Resting and touched heights, matching `ScrubBar`'s 12 / 20.
    private static let restingHeight: CGFloat = 12
    private static let touchedHeight: CGFloat = 20
    /// Generous enough to hit without aiming, independent of the bar's own
    /// height — a 12pt target would be unusable, and thickening the bar to
    /// reach 44 would make it a slab.
    private static let touchTargetHeight: CGFloat = 44

    public init(
        currentSeconds: TimeInterval,
        duration: TimeInterval,
        bufferedFraction: Double,
        onScrub: @escaping (TimeInterval) -> Void,
        onScrubbingChanged: @escaping (Bool) -> Void
    ) {
        self.currentSeconds = currentSeconds
        self.duration = duration
        self.bufferedFraction = bufferedFraction
        self.onScrub = onScrub
        self.onScrubbingChanged = onScrubbingChanged
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = duration > 0 ? min(max(currentSeconds / duration, 0), 1) : 0
            let knobX = width * fraction
            let barHeight = isTouching ? Self.touchedHeight : Self.restingHeight
            // Thinner than tvOS's 4/8. A remote's knob is read across a room and
            // has to survive that distance; a finger's is read at arm's length
            // and sits directly under the thing pointing at it, so the same
            // weight weighs more here.
            let knobWidth: CGFloat = isTouching ? 6 : 3
            // FLUSH at rest, exactly as `ScrubBar` is: the knob is the bar's own
            // height until the bar is touched, so nothing protrudes above or
            // below the track. It was 24 against a 12pt bar, which is what made
            // the whole control read as oversized when nothing was happening.
            let knobHeight: CGFloat = isTouching ? 32 : barHeight

            ZStack(alignment: .leading) {
                PlayerScrubTrackSurface(height: barHeight)
                Capsule().fill(.white.opacity(0.14))
                    .frame(width: width * CGFloat(min(max(bufferedFraction, 0), 1)), height: barHeight)
                // Square trailing edge so the played portion meets the knob
                // flush instead of tucking a curve behind it.
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(.white.opacity(isTouching ? 0.9 : 0.62))
                .frame(width: knobX, height: barHeight)
                // Square at rest, rounded once lifted — a rounded cap on a knob
                // the same height as the track just erodes the played edge.
                RoundedRectangle(cornerRadius: isTouching ? knobWidth / 2 : 0, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: isTouching ? 4 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: isTouching)
            .contentShape(Rectangle())
            .gesture(
                // `minimumDistance: 0` so a tap anywhere on the bar seeks there
                // rather than needing a drag to register at all.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isTouching {
                            isTouching = true
                            onScrubbingChanged(true)
                        }
                        let x = min(max(value.location.x, 0), width)
                        onScrub(duration * Double(x / width))
                    }
                    .onEnded { value in
                        let x = min(max(value.location.x, 0), width)
                        onScrub(duration * Double(x / width))
                        isTouching = false
                        onScrubbingChanged(false)
                    }
            )
        }
        .frame(height: Self.touchTargetHeight)
    }
}
