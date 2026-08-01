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
        .clipShape(RoundedRectangle(
            cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
            style: .continuous
        ))
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
