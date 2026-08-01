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

    public init(
        model: PlayerControlsModel,
        isCardOpen: Binding<Bool>,
        onRestart: @escaping () -> Void,
        onNextEpisode: @escaping () -> Void,
        onPreviousEpisode: @escaping () -> Void
    ) {
        self.model = model
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
        .animation(.easeInOut(duration: 0.24), value: openPanel)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Kept in step both ways: this view decides WHICH tab is open, the host
        // only ever needs to know THAT one is, and to be able to close it.
        .onChange(of: openPanel) { _, panel in
            let open = panel != nil
            if isCardOpen != open { isCardOpen = open }
        }
        .onChange(of: isCardOpen) { _, open in
            if !open, openPanel != nil { openPanel = nil }
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
            openPanel = (openPanel == category) ? nil : category
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
        .frame(height: InfoPanelView.cardHeight)
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
            let knobWidth: CGFloat = isTouching ? 8 : 4
            let knobHeight: CGFloat = isTouching ? 40 : 24

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                    .frame(height: barHeight)
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
                RoundedRectangle(cornerRadius: knobWidth / 2, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)
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
