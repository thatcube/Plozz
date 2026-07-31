#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI
import CoreModels

/// Lightweight value-type bag of options callbacks. Mirrors the tunable subset
/// of `PlayerActions` so the controls stay presentation-only.
@MainActor
struct PlayerOptionsActions {
    var togglePlayPause: () -> Void = {}
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    /// Pick the **second** (dual) subtitle track by option id, or `offID` to turn
    /// the second line off. Loads its cues into the overlay's secondary stream.
    var selectSecondarySubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
    /// Apply an edited subtitle **appearance** (from the in-player Style screen):
    /// the host updates the live overlay for instant preview and persists it.
    var setSubtitleStyle: (SubtitleStyle) -> Void = { _ in }
    /// Search the server's subtitle source (nil = preferred language).
    var searchRemoteSubtitles: (String?) -> Void = { _ in }
    /// Re-run the last subtitle search (e.g. after a per-search preference change).
    var refreshRemoteSubtitleSearch: () -> Void = {}
    /// Download the chosen remote subtitle and hot-load it into the player.
    var downloadRemoteSubtitle: (RemoteSubtitle) -> Void = { _ in }
    var playNextEpisode: () -> Void = {}
    var playPreviousEpisode: () -> Void = {}
    var restart: () -> Void = {}
}

/// The complete custom-player transport, stacked bottom-up:
///
///  * **Options panel slot** — the now-playing title, which cross-fades to an open
///    options panel. It sits ABOVE the track-control row, so a menu always opens
///    over its own buttons rather than under them.
///  * **Track controls** — Speed · Audio · Subtitles, directly above the scrub bar.
///    Reached by pressing **Up** from the scrub surface; Menu (or the idle
///    auto-hide) returns to the video, since nothing sits above them.
///  * **Scrub bar** — buffered/played fill + floating trickplay thumbnail.
///  * **Tab row** — beneath the scrubber; today just Info, later joined by siblings
///    (Chapters, …).
///  * **Info** — pressing **Down** from the scrub surface (or selecting the tab)
///    slides the Info card up from the bottom edge, pushing the Info tab up above
///    it, Apple-TV style. While the card is up the track-control row steps aside,
///    so the only chrome above the scrubber is the tab and its card.
///  * Playback keeps running while adjusting (Infuse-style) so track/speed/sync
///    changes have instant feedback.
///  * Capability-driven — controls the active engine can't honour are hidden.
///
/// All Siri-Remote *scrubbing* input is handled in UIKit
/// (`PlayerInputViewController`); this view never takes focus while the player is
/// in its scrub state because the host disables its interaction then.
struct PlayerControls: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    /// Called when the viewer backs out of the button row (Up, or Menu with no
    /// panel open) so the container can return focus to the scrub surface.
    let onExitToSurface: () -> Void

    enum Category: Hashable {
        case subtitles, audio, speed, sync, info, cast

        var title: LocalizedStringResource {
            switch self {
            case .subtitles:
                return LocalizedStringResource(
                    "player.category.subtitles",
                    defaultValue: "Subtitles",
                    comment: "Tab in the in-player options panel listing subtitle tracks."
                )
            case .audio:
                return LocalizedStringResource(
                    "player.category.audio",
                    defaultValue: "Audio",
                    comment: "Tab in the in-player options panel listing audio tracks."
                )
            case .speed:
                return LocalizedStringResource(
                    "player.category.speed",
                    defaultValue: "Speed",
                    comment: "Tab in the in-player options panel for playback speed."
                )
            case .sync:
                return LocalizedStringResource(
                    "player.category.sync",
                    defaultValue: "A/V Sync",
                    comment: "Tab in the in-player options panel for audio/subtitle delay."
                )
            case .info:
                return LocalizedStringResource(
                    "player.category.info",
                    defaultValue: "Info",
                    comment: "Tab in the in-player options panel showing playback details."
                )
            case .cast:
                return LocalizedStringResource(
                    "player.category.cast",
                    defaultValue: "Cast",
                    comment: "Tab beneath the in-player scrub bar listing the cast of what is playing."
                )
            }
        }

        var icon: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .audio: return "waveform"
            case .speed: return "speedometer"
            case .sync: return "slider.horizontal.below.square.and.square.filled"
            case .info: return "info.circle"
            case .cast: return "person.2"
            }
        }
    }

    enum FocusSlot: Hashable {
        case button(Category)
        /// Invisible strip above the Info tab. Focusing it IS the "leave the card"
        /// gesture — see `infoExitGuide`.
        case infoExit
        case infoNext       // Info panel: Next Episode
        case infoPrev       // Info panel: Previous Episode
        case infoRestart    // Info panel: Restart
        case infoStats      // Info panel: Playback Info (diagnostics) toggle
        /// One face in the Cast card, by position in the row.
        case castMember(Int)
        /// Back out of a cast member's details to the row.
        case castBack
        /// One title in a cast member's credits row, by position.
        ///
        /// Focusable purely so it can be READ: at the pane's fixed height a
        /// poster is 140pt wide, which is legible as art but not as type until
        /// something enlarges it. Focus is the only enlargement tvOS offers
        /// without stealing height from the row itself.
        case castCredit(Int)
        /// Leave the film for this person's own page.
        case castMore
        case row(Int)
        case edit       // Subtitles header ✎ Edit (appearance) button
        case download   // Trailing "Search for subtitles…" row
        case subBack    // Back control inside a Subtitles sub-screen
        case subSync    // Subtitles header Sync (timing) button
    }

    /// Sub-screens of the Subtitles panel. `tracks` is the default list; the
    /// header ✎ Edit opens `style`, and the trailing row opens `download`. The
    /// Style screen has its own detail sub-screens (`styleOutline` / `styleBackground`
    /// / `styleDual`). Back steps to a screen's PARENT rather than closing the panel.
    enum SubtitleScreen: Equatable {
        case tracks, download, sync, style, styleFont, styleOutline, styleBackground, styleDual

        /// The screen a Back / Menu press should return to.
        var parent: SubtitleScreen {
            switch self {
            case .tracks, .download, .sync, .style: return .tracks
            case .styleFont, .styleOutline, .styleBackground, .styleDual: return .style
            }
        }

        /// Whether this is the Style editor or one of its detail sub-screens (they
        /// share the taller upward-growing panel). Sync is a compact, bottom-anchored
        /// screen like the track list / Download, so it stays out of this family.
        var isStyleFamily: Bool {
            switch self {
            case .style, .styleFont, .styleOutline, .styleBackground, .styleDual: return true
            case .tracks, .download, .sync: return false
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzHDRDisplayActive) private var hdrDisplayActive

    @State private var openPanel: Category?
    @State private var subtitleScreen: SubtitleScreen = .tracks
    @FocusState private var focus: FocusSlot?

    /// Named coordinate space spanning the WHOLE controls layer, so the Speed
    /// button's leading edge can be measured in the same frame its panel — laid out
    /// in a different sub-stack of the cluster — is positioned in.
    private static let controlsSpace = "PlayerControlsLayer"

    /// Coordinate space of the track-control row, which the options menus are
    /// anchored to. See `trackControlButtons`.
    private static let trackControlsSpace = "PlayerTrackControls"

    /// Side margin of the controls layer. Subtracted from the whole-layer
    /// measurement above so a panel aligned to a button lands in the cluster's own
    /// content coordinates.
    private static let horizontalMargin: CGFloat = 60

    /// Extra lift under an open options panel so it clears the transport instead of
    /// sitting right on top of the scrub bar.
    private static let panelLift: CGFloat = 18

    /// Measured leading-edge X of the Speed button, in `trackControlsSpace`. The
    /// Speed panel left-aligns to this so it opens directly above its own button.
    @State private var speedButtonLeading: CGFloat = 0

    /// Measured width of the track-control row, so a button-aligned menu wider than
    /// the row can be clamped instead of running off the screen.
    @State private var trackControlsWidth: CGFloat = 0

    /// Measured top edge of the track-control row, in GLOBAL space, so the menus can
    /// sit just above the buttons while living outside the transport.
    @State private var trackControlsTop: CGFloat = 0

    /// The controls layer's own bottom edge, in the same GLOBAL space.
    @State private var controlsBottom: CGFloat = 0

    /// The transport control that was focused when the current panel was opened.
    /// Restored (deferred) whenever the panel fully closes so focus always lands
    /// back where the user started — no matter how deep the panel's sub-screens
    /// went. See `restoreFocus(_:)` for why the restore is deferred.
    @State private var panelReturnFocus: FocusSlot?

    /// Whether the now-playing title/description block is shown. Distinct from
    /// `openPanel == nil` so the block can *lag* on the way back: opening a panel
    /// hides it immediately, but closing one waits ~0.5s before it fades in again
    /// (otherwise it snaps back the instant the panel starts collapsing).
    @State private var titleVisible = true

    /// Full height available to the controls layer (captured via a background
    /// GeometryReader). Drives how tall the Subtitle Style panel grows so it can
    /// climb toward the top edge while staying pinned to the bottom cluster.
    @State private var availableHeight: CGFloat = 0

    /// Measured height of the transport block (scrubber + button row). Combined
    /// with `availableHeight`, it lets the Style panel's top margin match its side
    /// margin exactly rather than relying on hand-tuned constants.
    @State private var transportHeight: CGFloat = 0

    /// The Style panel's natural content height, remeasured whenever a sub-screen
    /// swaps in or a row appears/disappears. Only the glass box's clip window
    /// animates to this value; the rows themselves are always laid out at full
    /// size and clipped, so they never fade or spill during the height morph.
    @State private var styleBodyHeight: CGFloat = 0

    /// Which panel `styleBodyHeight` was last measured for. Lets the height reader
    /// tell a *fresh open* (snap to natural size) apart from a *content morph within
    /// the same panel* (animate the box). Reset when the panel closes so the next
    /// open always snaps.
    @State private var measuredPanel: Category? = nil

    /// Last measured natural body height per panel, so a *reopen* can seed
    /// `styleBodyHeight` with the right value from frame one. That keeps the panel in
    /// the measured (`ScrollView`) branch from the first frame instead of starting in
    /// the pre-measure branch and structurally swapping to the ScrollView a frame
    /// later — that swap tore down and rebuilt the focusable rows mid-open, letting
    /// the focus engine write its default (top row) back into `focus` before our
    /// intended `.row(selected)` could claim it. Seeding removes the swap, so initial
    /// focus lands consistently on the active row. (For Subtitles we only cache the
    /// tracks-screen height, since a fresh open always starts on the track list.)
    @State private var cachedPanelHeight: [Category: CGFloat] = [:]
    /// The cast member whose details fill the Cast card, or `nil` for the row.
    /// Cleared whenever the Cast card is left, so reopening it always starts at
    /// the row rather than on whoever was last inspected.
    @State private var castDetailPerson: MediaPerson?
    /// Suppresses tab switching while the cast row is being restored.
    ///
    /// Backing out of a person's details rebuilds the row, and for an instant
    /// there is nothing focusable in it — so the engine falls back to the
    /// nearest candidate, which is the Info tab, and `selectCardTab` faithfully
    /// switches the card because it cannot tell a fallback from a deliberate
    /// move. That is why Back landed on Info instead of the cast row.
    ///
    /// The same shape as `entryFocusTarget`, which exists for the identical
    /// reason during a Down entry.
    @State private var isRestoringCastRow = false
    /// Bumped to ask the Cast panel to close a person's details. See `handleExit`.
    @State private var castCloseRequest = 0
    /// Which card tab the card is DRAWING, including while it parks off-screen.
    ///
    /// The card is one stage whose content switches, and switching it replaces
    /// the view — a replaced view cannot animate its exit, so clearing
    /// `openPanel` on close swapped Cast out for Info mid-flight and the card
    /// simply vanished instead of travelling. This follows `openPanel` while a
    /// card tab is open and keeps its last value once it closes, so the thing
    /// being parked is the thing the viewer was looking at.
    ///
    /// Assigned at every site that opens a card tab rather than from an
    /// `onChange`, which lands a render too late and briefly showed the previous
    /// tab's content on reopening.
    @State private var parkedCardTab: Category = .info

    var body: some View {
        ZStack {
            // Measures the box the ZStack's CHILDREN are laid out in. The outer
            // `.background` reports a different one (960 tall, ending at 1020) than
            // the children actually get (ending at 1080) — telemetry caught the menus
            // sitting exactly that 60pt low, on top of the buttons. A sibling probe is
            // the only way to measure the same box the menu layer is padded within.
            Color.clear
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ControlsBottomKey.self,
                            value: proxy.frame(in: .global).maxY
                        )
                    }
                )
            dimScrim
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomCluster
                    .opacity(model.controlsVisible ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
            .animation(.easeInOut(duration: 0.3), value: styleEditing)
            // A member of the ZStack, NOT an `.overlay` on it. An overlay attached
            // after `.ignoresSafeArea()` still gets the system safe area in its
            // environment, so tvOS inset the editor by 60/90 on top of its own 60pt
            // margin — pushing it ~120 down and ~150 in, nowhere near the margin the
            // rest of the player uses. In here it shares the cluster's coordinate
            // space, so the same constant means the same thing for both.
            optionsPanelLayer
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        // One space across the whole layer: the Speed button and its panel sit in
        // different sub-stacks of the cluster, so the alignment measurement has to
        // cross them.
        .coordinateSpace(name: Self.controlsSpace)
        .onPreferenceChange(SpeedButtonLeadingKey.self) { speedButtonLeading = $0 }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ControlsHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ControlsHeightKey.self) { availableHeight = $0 }
        .onPreferenceChange(ControlsBottomKey.self) { controlsBottom = $0 }
        // Menus animate open/closed on their own clock. Keyed on `optionsPanel`, which
        // is nil for Info, so this can't fire for — or retime — the Info reveal.
        .animation(.easeInOut(duration: 0.2), value: optionsPanel)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipGesture.hintVisible)
        .onChange(of: model.controlBarVisible) { _, focused in
            titleVisible = true
            guard focused else {
                // Includes the idle auto-hide firing with the card open: park the
                // cluster on the reveal clock, never by snapping.
                withAnimation(revealClock) { openPanel = nil }
                focus = nil
                model.isPanelOpen = false
                return
            }
            // Where the viewer entered from decides what they get: Down opens the
            // Info card with its tab focused (the tab row behaves like a segmented
            // control above the card), Up lands in the track-control row above the
            // scrubber. The write is SYNCHRONOUS — the container holds its focus
            // update until `controlBar.focusArmed` says we've applied it, so the
            // engine finds the intended target already in place instead of picking
            // its own and having ours yank focus across the row a beat later.
            switch model.controlBar.entry {
            case .info:
                // The tab you last had open, not always Info.
                //
                // `parkedCardTab` already tracks it — it exists so the card can
                // keep drawing its own content while it parks — so reopening the
                // same one is simply using that value. It also means the card's
                // content does not change at the moment the reveal starts, which
                // it did when Down always forced Info.
                let tab = Self.usesBottomCard(parkedCardTab) && isTabVisible(parkedCardTab)
                    ? parkedCardTab
                    : .info
                panelReturnFocus = .button(tab)
                revealInfoCard(tab)
                focus = .button(tab)
            case .trackControls:
                openPanel = nil
                focus = initialFocus
            }
            model.controlBar.focusArmed = true
        }
        .onChange(of: focus) { _, slot in
            // Any focus move between control-bar buttons is activity — bump so the
            // container restarts its idle countdown instead of hiding mid-navigation.
            model.controlBarActivity &+= 1
            // Invariant: the tab is focused ONLY with its card open. It's enforced
            // structurally by `infoTabFocusable` (the tab isn't even in the focus
            // order otherwise); this covers the one moment the gate can't — a Down
            // entry, where focus is applied in the same update that opens the card.
            // Not while the cast row is being restored. Backing out of a
            // person's details tears the row down, and for an instant it holds
            // nothing focusable — so the engine parks focus on the nearest
            // candidate, the Info tab, and this rule faithfully opens the Info
            // card. That is the whole "Back goes to Info" bug: neither
            // `toggle` nor `selectCardTab` was ever involved, which is why
            // guarding those changed nothing.
            // Never during an entry. The engine takes a couple of frames to
            // settle and can touch a tab that is not the entry's target on the
            // way — harmless when this rule only ever opened Info and Info was
            // the only entry destination, but now that Down reopens the last tab
            // a transient landing on Info would switch the card out from under
            // the reveal. `entryFocusTarget` is non-nil for exactly that window.
            if case let .button(tab)? = slot, Self.usesBottomCard(tab),
               openPanel != tab, !isRestoringCastRow, entryFocusTarget == nil {
                revealInfoCard(tab)
            }
            // Focus reached the strip above the tab, which only a deliberate Up from
            // the tab itself can do: that's the exit gesture. Acting on where focus
            // LANDED — rather than on the press that may have caused it — is what
            // makes this reliable; see `infoExitGuide`.
            if slot == .infoExit { closeInfoCard() }
            // Focus reaching the tab row with a person's details still open
            // means the viewer pressed Up out of the detail. Close it, so the
            // card is back on its row and a second Up can leave the card
            // entirely — the exit strip is deliberately inert mid-detail, and
            // without this that left Up doing nothing at all.
            // …but never while the drill is in flight. Opening takes a couple of
            // frames during which the engine can touch a tab on its way to the
            // pane, and treating that as an Up gesture closed the details
            // instantly. `isRestoringCastRow` covers exactly that window, in
            // both directions.
            if case .button? = slot, castDetailPerson != nil, !isRestoringCastRow {
                castCloseRequest &+= 1
            }
            // `infoTabSettled` distinguishes "the tab has been focused for a beat"
            // from "focus arrived on the tab in this very event". A move command and
            // the focus change it causes land in the same turn, and the order isn't
            // guaranteed — so an Up press walking a card button onto the tab could
            // otherwise be mistaken for an Up press ON the tab, and would close the
            // card the viewer was just entering. Settling one runloop turn later
            // makes the two cases distinguishable without guessing at delivery order.
        }
        .onChange(of: openPanel) { _, panel in
            // Leaving Cast always returns it to the row, so reopening never lands
            // mid-detail on whoever was last inspected.
            if panel != .cast { castDetailPerson = nil }
            // Surface whether a menu is open so the container pins the transport
            // visible while one is up, and count the open/close as bar activity.
            // Deliberately EXCLUDES the Info card. `isPanelOpen` pins the transport
            // on screen (ControlsAutoHidePolicy returns `.stayVisible`, which ends the
            // auto-hide task), which is right for a menu the viewer opened mid-task —
            // but the card is now where a plain Down press lands, so counting it left
            // the transport up forever after every Down entry. The card behaves like
            // the old control bar instead: idle for the timeout and it hides.
            model.isPanelOpen = panel != nil && panel != .info
            // ANY card tab, not just Info.
            //
            // This holds the scrub bar in its focused shape for the whole reveal.
            // Excluding Cast meant that leaving it, focus returning to the scrub
            // surface resized the bar (12→20 tall, knob 4→8) on the bar's OWN
            // 0.2s curve while the cluster carrying it travelled on the reveal's
            // 0.5s spring — the exact failure `ScrubBar` documents at the
            // `focused` line, and why only the bar looked wrong while everything
            // around it moved perfectly.
            if let panel {
                model.controlBar.infoCardOpen = Self.usesBottomCard(panel)
            } else {
                model.controlBar.infoCardOpen = false
            }
            model.controlBarActivity &+= 1
            subtitleScreen = .tracks
            guard let panel else {
                // Panel fully closed. Reset the measured panel height so the next
                // open snaps to its natural size instead of morphing from a stale
                // value. (We deliberately DON'T reset on the tracks↔Style flip so
                // that Edit/Back morphs the box height between them.)
                styleBodyHeight = 0
                measuredPanel = nil
                // Return focus to whatever transport control opened it (skip while
                // the whole bar is hiding — focus is intentionally cleared then).
                // Then let the title fade back in after a short beat.
                if model.controlBarVisible { restoreFocus(panelReturnFocus) }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    if openPanel == nil { titleVisible = true }
                }
                return
            }
            // The Info card doesn't use this: its title fade rides the reveal clock
            // (see `titleBlock`). Flipping it here would fade the title on the menus'
            // curve at the same time, which is exactly the kind of near-miss timing
            // that made the transport look like separate pieces.
            if panel != .info { titleVisible = false }
            // Seed the box height from the last time this panel was open so it renders
            // in the measured (ScrollView) branch immediately — no pre-measure→measured
            // structural swap that would rebuild the rows and knock initial focus to the
            // top. A cache miss (first open) falls back to 0 → pre-measure branch.
            styleBodyHeight = cachedPanelHeight[panel] ?? 0
            // A cache hit means we already "know" this panel's height, so a later
            // same-panel change is a morph (animate); a miss leaves it unmeasured so the
            // first measurement snaps.
            measuredPanel = styleBodyHeight > 0 ? panel : nil
            // Land initial focus on the active/selected row. This MUST be deferred to
            // the next runloop tick: opening a panel simultaneously inserts the panel's
            // rows and disables the transport button that currently holds focus, which
            // forces tvOS to run its own default-focus pass. That pass runs after this
            // closure (once the rows exist) and picks the section's first row. A
            // synchronous write here raced it (sometimes we won → active row, sometimes
            // the engine won → top/Style), and the declarative `prefersDefaultFocus`
            // approach loses to the enclosing ScrollView, which always defaults to its
            // first item (see ProfilePickerView: tvOS declarative default focus is
            // unreliable inside scroll containers). A single deferred write runs AFTER
            // the engine's pass, so it reliably lands — the same mechanism `restoreFocus`
            // already uses on close. Any one-frame highlight of the engine's pick happens
            // while the panel is still at ~0 opacity (mid fade-in), so it's imperceptible.
            restoreFocus(preferredPanelFocus)
        }
        .onChange(of: model.subtitleDownload.state) { _, state in
            // When search results land (async) while the Download screen is open,
            // move focus onto the first result so it's immediately actionable —
            // instead of leaving it parked on Back. Deferred for the same reason as
            // panel-open focus: let tvOS's own pass run first, then land ours.
            guard openPanel == .subtitles, subtitleScreen == .download else { return }
            if case .results = state { restoreFocus(.row(0)) }
        }
        .plozzRemoteCommands(
            onExit: handleExit,
            onPlayPause: actions.togglePlayPause,
            onMove: handleMove
        )
    }

    /// Directional presses that the focus engine can't resolve on its own.
    ///
    /// The scrub bar is the hub. From the track row **Down** hands focus back to it
    /// (never sideways-and-down to the Info tab) and **Up** does nothing — nothing
    /// sits above that row, so Menu is the way back to the video. The Info tab is
    /// the card's header: **Up** from it closes the card and returns to the scrub
    /// bar, while Up from a card button just walks onto the tab (the engine's job,
    /// and why the tab must have *settled* before its own Up counts).
    private func handleMove(_ direction: PlozzMoveCommandDirection) {
        switch direction {
        case .up:
            // Nothing to do. Leaving the card upward is handled by the focus engine
            // moving onto `infoExitGuide`, not by interpreting this press: when the
            // card is open, an Up press and the focus change it causes arrive in an
            // order tvOS does not guarantee, so "was this press ON the tab, or did it
            // MOVE me here?" cannot be answered here. Reading the press led to Up
            // from a card button skipping the tab and dropping to the scrub bar.
            break
        case .down:
            // Down from a track control returns to the scrub bar. Handing focus back
            // to the surface here also takes the whole controls layer out of the
            // focus order, so the engine can't complete its own move onto the Info
            // tab — Info stays a deliberate Down-from-the-scrubber gesture.
            guard openPanel == nil, case .button(let category) = focus, category != .info else { return }
            onExitToSurface()
        case .left, .right:
            break
        }
    }

    /// Bring the Info card in, on the reveal clock.
    ///
    /// The animation is stated at the call site (rather than left entirely to the
    /// cluster's `.animation(value: infoMode)`) so the card's arrival can never be
    /// captured by an ambient transaction from whatever caused it — a focus change,
    /// a Select press, or the container flipping the transport visible.
    private func revealInfoCard(_ category: Category = .info) {
        parkedCardTab = category
        // SYNCHRONOUSLY, in the same pass that opens the card.
        //
        // `onChange(of: openPanel)` also maintains this, but that lands a render
        // later — and for that one frame the bar has no reason to stay in its
        // focused shape, so it shrinks and then grows back on its own 0.2s
        // curve. Invisible at a normal pace, plainly disjointed when opening and
        // closing quickly. Clearing it stays with the `onChange`, where being a
        // beat late is exactly what the closing travel wants.
        model.controlBar.infoCardOpen = true
        withAnimation(revealClock) { openPanel = category }
    }

    /// The reveal's animation, honouring Reduce Motion.
    private var revealClock: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : Self.infoReveal
    }

    /// Dismiss the Info card and hand focus back to the scrub bar.
    ///
    /// The card and its tab are one unit, so they always leave together: leaving the
    /// tab focused over a closed card is exactly the state the focus invariant in
    /// `onChange(of: focus)` forbids (it would immediately re-open the card).
    private func closeInfoCard() {
        withAnimation(revealClock) { openPanel = nil }
        onExitToSurface()
    }

    // MARK: Bottom cluster (title / options panel + scrubber + tab row + Info card)

    private var bottomCluster: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The context slot directly above the scrub bar: normally the now-playing
            // title/description; when an options panel opens it cross-fades to the
            // panel (the title/description are repetitive with it, so they fade out).
            // The Info card is NOT part of this slot — it enters from the bottom edge
            // below the tab row (see `infoCard`).
            // Transport block (title + track controls + scrubber + tab row). Faded
            // out — never removed — while the full-height appearance editor is open,
            // so the live subtitles behind it are unobstructed.
            //
            // It MUST stay mounted: the options menus are an overlay on the track
            // controls, so removing the block took the open Style editor down with it
            // and the panel simply never appeared.
            VStack(alignment: .leading, spacing: 18) {
                titleAndControlsRow
                scrubberRow
                    // The transport steps aside for the Info card: faded in
                    // place rather than removed, so the tab and its card never
                    // shift as it goes.
                    .opacity(infoMode ? 0 : 1)
                    // The scrub bar does NOT fade for the card. It travels.
                    //
                    // It used to fade out as the card opened, which meant that on
                    // the way back it had to fade in *while* moving — and however
                    // that fade was timed it was wrong. Left to the reveal's
                    // spring it was still nearly transparent for most of the
                    // journey, so it seemed to appear already in place while
                    // everything else moved to meet it; given a short fade of its
                    // own it popped in early, a second motion inside the first.
                    // Measured frames ruled out any reflow — scrubber, tabs and
                    // card travel identically leaving Cast and leaving Info
                    // (565→867, 665→967, 762→1080) — so the fade was the only
                    // thing that ever differed from the rest of the cluster.
                    //
                    // The bar's own opacity carries no animation of its own: it
                    // rides the reveal, like the rest of the block.
                    .allowsHitTesting(!infoMode)
                    .opacity(chromeHidden ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: chromeHidden)
                tabRow
                    .opacity(chromeHidden ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: chromeHidden)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TransportHeightKey.self, value: proxy.size.height)
                }
            )
            // NOTE: no block-level `.opacity` for the Style editor. Opacity applies
            // to a view's whole rendered subtree — overlays included — and cannot be
            // undone from inside, so fading the block faded the open panel with it.
            // Each piece of chrome hides itself instead (see `chromeHidden`), leaving
            // the menu overlay, which hangs off the buttons, unaffected.
            // The Info card is a PERMANENT member of the stack, never inserted or
            // removed. That's the whole trick behind the reveal moving as one unit:
            // the layout always holds the revealed arrangement (card at the bottom,
            // tab above it), and the resting look is produced purely by translating
            // the cluster down so the card sits just off the bottom edge. Opening it
            // is then a single transform on a fixed stage — nothing appears, nothing
            // reflows, so no part can arrive on its own clock. (Same approach as the
            // series-detail hero/browser reveal; see SeriesEpisodeBrowserLayout.)
            infoCard
                .plozzFocusSection()
                // Widen the stack's 18pt gap to the cluster's bottom margin. That
                // equality is load-bearing: it's what makes ONE offset put the
                // card exactly off-screen at rest AND the tab exactly at its
                // resting height (see `infoCardLift`).
                .padding(.top, Self.infoCardGap - 18)
                // Even up the bottom inset with the sides (see `infoCardInset`).
                .padding(.bottom, Self.infoCardBottomPad)
                // The extra sliver of travel that buys a gap tighter than the
                // tab's margin. No `.animation` of its own — it rides the same
                // reveal transaction as the cluster's offset, which is what makes
                // the two land together (see `infoCardCatchUp`).
                .offset(y: infoMode ? 0 : Self.infoCardCatchUp)
                // Off-screen but still in the hierarchy, so its buttons must be out
                // of the focus order. `InfoActionButtonStyle` ignores `\.isEnabled`,
                // so this doesn't grey the card.
                //
                // Also out for the duration of an ENTRY, even a Down entry that is
                // opening this very card: `infoMode` is already true by the time the
                // engine runs its pass, so without this the card's four buttons were
                // candidates alongside the tab and a Down press could land inside the
                // card body. Narrowing the order to the entry's own target is the
                // whole reason the engine can't overrule us (see `entryFocusTarget`).
                .disabled(!infoMode || entryFocusTarget != nil)
        }
        // THE reveal: the entire cluster — options slot, track controls, scrub bar,
        // tab and card — travels as one rigid unit. At rest it's parked far enough
        // down that the card clears the bottom edge; revealed it sits at its natural
        // place. Nothing moves relative to anything else, which is what stops the
        // card reading as detached from the transport above it.
        .offset(y: infoMode ? 0 : Self.infoCardLift)
        .onPreferenceChange(TransportHeightKey.self) { transportHeight = $0 }
        // The reveal's clock, and — deliberately — the ONLY animation modifier at
        // cluster level that can fire while it runs. Anything else here retimes the
        // travel mid-flight, however unrelated it looks: every other fade is scoped
        // to the view it belongs to. Reduce Motion drops the movement.
        .animation(revealClock, value: infoMode)
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        .animation(Self.transportFadeAnimation(scrubbing: model.isScrubbing), value: model.isScrubbing)
        .padding(.horizontal, Self.horizontalMargin)
        // Fixed, whatever is open. These used to widen to an even 60 for the Style
        // editor, back when the editor was laid out INSIDE this cluster and the whole
        // thing flipped to top-anchored. The editor has its own screen-level layer
        // now, so that only had one effect left: the extra 12pt at the bottom lifted
        // the cluster, and the Info card — parked flush against the screen edge —
        // peeked into view by exactly that much whenever Style was open.
        .padding(.top, 90)
        .padding(.bottom, Self.bottomMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The dim scrim behind the controls. A *fixed*, bottom-anchored gradient that
    /// only fades (it never moves), so it always covers the transport/title area —
    /// unlike the old cluster `.background`, which slid with the cluster's anchor
    /// flip and briefly left a bright gap when the Style editor closed. Fully
    /// transparent while editing so the live subtitles read clearly.
    private var dimScrim: some View {
        let height = max(availableHeight * 0.55, 420)
        return LinearGradient(
            colors: [.clear, .black.opacity(0.7)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity((model.controlsVisible && !styleEditing) ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: model.controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: Title (episode line above the series title, bottom-left)

    /// The episode line ("S1, E2 • Episode Title") sits *above* the prominent
    /// series/movie title, Apple-TV style. The whole block lives at the bottom
    /// just above the scrub bar and fades out fast while scrubbing so the scrub
    /// surface stays uncluttered (the times stay).
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(model.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .allowsHitTesting(!model.isScrubbing)
    }

    private var scrubberRow: some View {
        VStack(spacing: 8) {
            ScrubBar(
                model: model,
                palette: palette,
                leadingInset: 60,
                trailingInset: 60
            )
                .frame(height: 44)
                .frame(maxWidth: .infinity)
            underBarTimes
                .frame(height: 30)
                .frame(maxWidth: .infinity)
        }
    }

    /// The time row *under* the bar. The current-position label tracks the scrub
    /// head horizontally — all the way to the very end — with the status glyph
    /// hanging off its right edge (free to slide into the trailing padding). The
    /// remaining time stays pinned at the right but fades out + away once the
    /// moving current time closes within ~16px of it, so the current time is never
    /// blocked. Everything is absolutely positioned inside a fixed-height zone so
    /// the bar never shifts when the glyph appears/clears.
    private var underBarTimes: some View {
        let fadeGap: CGFloat = 16
        let curLabel = Self.timeLabel(model.displaySeconds)
        let remLabel = "-" + Self.timeLabel(max(0, model.duration - model.displaySeconds))
        // Deterministic, synchronous text widths. The SwiftUI `.background`/
        // `PreferenceKey` measuring trick does NOT propagate through `.hidden()`
        // here (verified on-device: the preference never fired, so the widths
        // stayed 0 → no right-edge clamp and no fade). Measuring with UIKit using
        // the matching monospaced-digit font is exact and needs no layout pass.
        let curW = Self.measuredTimeWidth(curLabel)
        let remW = Self.measuredTimeWidth(remLabel)
        return GeometryReader { geo in
            let width = geo.size.width
            let midY = geo.size.height / 2
            let knobX = width * CGFloat(model.progressFraction)
            let halfCur = curW / 2
            // The scrub track spans the full zone width [0, width] (the ScrubBar's
            // insets only let the thumbnail overhang — the track itself is full
            // width), so the head maps straight to knobX. Centre the label on the
            // head, but clamp so its RIGHT edge stops exactly at the bar's right
            // edge (x = width) and its LEFT edge never crosses the bar's left edge.
            let centerX = min(max(knobX, halfCur), max(halfCur, width - halfCur))
            let currentRightEdge = centerX + halfCur
            // The remaining time is pinned to the bar's right edge; its left edge
            // sits at width - remW.
            let remainingLeftEdge = width - remW
            // When the status glyph (pause/seek/skip) is showing it hangs ~40px
            // past the current-time text's right edge, so NEAR THE VERY END it can
            // land on top of the remaining time even though the time text hasn't
            // reached it. Treat the glyph's right edge as the collision point
            // whenever it's visible (it's faded out during an active scrub) so the
            // remaining time still does the same fade — just earlier by the glyph's
            // reach. Outside this edge case the glyph isn't near the end, so the
            // time is never hidden early.
            let glyphShown = !model.isScrubbing
                && (model.skipGesture.hintVisible || (model.isPaused && model.intendsPause) || model.isSeeking)
            let glyphReach: CGFloat = glyphShown ? 40 : 0
            // Fade the remaining time once the current time's (or glyph's) right
            // edge closes within the gap.
            let remainingHidden = currentRightEdge + glyphReach + fadeGap >= remainingLeftEdge

            // Current position — centred on the (clamped) scrub head, tracking it.
            // The glyph hangs off the right edge as an overlay so it can't shift
            // the time, and fades (no movement) while actively scrubbing, returning
            // when the scrub ends, like the other transport elements.
            Text(curLabel)
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .shadow(radius: 3)
                .overlay(alignment: .trailing) {
                    statusGlyph
                        .frame(width: 30, height: 30)
                        .offset(x: 40)
                        .opacity(model.isScrubbing ? 0 : 1)
                        // Fades with the rest of the transport (title + buttons):
                        // vanish instantly when a scrub starts, then fade back in
                        // together with them after a delay once it stops — so rapid
                        // multi-scrubs don't flash anything back between swipes.
                        .animation(
                            Self.transportFadeAnimation(scrubbing: model.isScrubbing),
                            value: model.isScrubbing
                        )
                }
                .position(x: centerX, y: midY)

            // Remaining time, pinned at the bar's right edge — fades out (in
            // place, no drift) when the current time / glyph approaches.
            Text(remLabel)
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
                .shadow(radius: 3)
                .opacity(remainingHidden ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: remainingHidden)
                .frame(width: width, alignment: .trailing)
                .position(x: width / 2, y: midY)
        }
        // No `.animation(value: isPaused/isSeeking)` here on purpose. The glyph's
        // pause↔spinner swap must be INSTANT: the pause glyph is mounted (hidden)
        // during a scrub, and animating the swap let it play a scale+opacity
        // *removal* transition just as the parent overlay faded back in — you'd see
        // a half-size pause icon try to appear and vanish on a seek-without-
        // pausing. The parent's `isScrubbing` transport fade still handles the
        // overall reveal; the content underneath swaps with no animation of its own.
    }

    /// Status glyph beside the current time under the bar. Priority, highest
    /// first:
    ///  1. a forward/back skip indicator during a skip burst,
    ///  2. the loading spinner while a committed seek is resolving — this wins
    ///     over the pause glyph UNCONDITIONALLY: while anything is loading the
    ///     viewer must see ONLY the spinner, never a pause icon alongside it,
    ///  3. a circular pause glyph while *intentionally* paused (a landed,
    ///     finished-loading pause).
    ///
    /// The pause glyph requires `isPaused` AND `intendsPause` AND `!isScrubbing`.
    /// `intendsPause` filters out the engine's transient post-seek pause (the
    /// viewer never pressed pause). `!isScrubbing` is the decisive one: a scrub
    /// pauses the stream for preview, so `isPaused`/`intendsPause` are BOTH true
    /// mid-scrub — without this gate the pause glyph is the rendered content
    /// during the scrub, and at commit its swap to the spinner gets animated by
    /// the overlay's `isScrubbing` fade, cross-dissolving a half-faded pause icon
    /// into the spinner (the seek-without-pausing flicker). Gating on
    /// `!isScrubbing` keeps the content at none→spinner across the whole
    /// scrub→commit window, so a manual pause is the ONLY thing that ever shows it.
    @ViewBuilder private var statusGlyph: some View {
        if model.skipGesture.hintVisible {
            Image(systemName: model.skipGesture.hintForward
                ? model.skipGesture.forwardInterval.forwardSymbol
                : model.skipGesture.backwardInterval.backwardSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if model.isSeeking {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else if model.isPaused && model.intendsPause && !model.isScrubbing {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
        }
    }

    // MARK: Control rows

    /// The now-playing title and the track controls share ONE line directly above the
    /// scrub bar: title at the leading edge, controls at the trailing edge, aligned
    /// along their bottoms. (Stacked, whichever went on top sat a whole block higher
    /// than the timeline it belongs to.)
    private var titleAndControlsRow: some View {
        HStack(alignment: .bottom, spacing: 32) {
            titleBlock
                // Two separate reasons to hide, each on its own clock. Opening a MENU
                // fades the title on the menus' curve (`titleVisible`); the Info
                // reveal is a different motion and the title must travel with the
                // rest of the transport, so that half rides the reveal clock via
                // `infoMode` and is deliberately NOT folded into `titleVisible`.
                //
                // Both are scoped to the title rather than the cluster: a
                // cluster-level modifier retimes whatever is in flight, and this one
                // caught the reveal a frame in — handing a 0.5s spring to a 0.28s
                // curve, which read as a lurch.
                .opacity(titleVisible && !chromeHidden && !infoMode ? 1 : 0)
                .animation(.easeInOut(duration: 0.28), value: titleVisible)
                .animation(revealClock, value: infoMode)
            // The controls are laid out FIRST (higher priority) at their intrinsic
            // width; the title then takes what's left and truncates. Without this a
            // long series name would push the buttons off the trailing edge, since
            // the title's own frame is greedy.
            trackControlButtons
                .layoutPriority(1)
        }
    }

    /// The track controls (Speed · Audio · Subtitles), at the trailing edge their
    /// panels open from. An open options panel floats above the whole transport, so
    /// the menu always sits above its own buttons.
    ///
    /// Faded out — not removed — whenever the Info card is up (the card owns the
    /// screen then), so hiding it never reflows the scrub bar.
    private var trackControlButtons: some View {
        HStack(spacing: 20) {
            ForEach(model.trackControlCategories, id: \.self) { category in
                Button {
                    toggle(category)
                } label: {
                    Label(category.title, systemImage: category.icon)
                        .labelStyle(.iconOnly)
                }
                .playerGlassButton(prominent: openPanel == category)
                .focused($focus, equals: .button(category))
                .disabled(entryLocksOut(.button(category)))
                .background {
                    // Publish the Speed button's leading edge so its panel can
                    // open left-aligned to the button rather than the far edge.
                    if category == .speed {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SpeedButtonLeadingKey.self,
                                value: proxy.frame(in: .named(Self.trackControlsSpace)).minX
                            )
                        }
                    }
                }
            }
        }
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .animation(Self.transportFadeAnimation(scrubbing: model.isScrubbing), value: model.isScrubbing)
        // Applied INSIDE this property, i.e. before `titleAndControlsRow` attaches the
        // menu overlay — so the buttons fade for the Style editor while the menu
        // hanging off them does not.
        .opacity(chromeHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.3), value: chromeHidden)
        // Clear out once the Info card takes over, so the tab and its card are the
        // only chrome left. Opacity ONLY — it's already travelling with the rest of
        // the cluster, and an offset of its own is exactly the kind of second
        // movement that made the reveal look like separate pieces.
        .opacity(infoMode ? 0 : 1)
        .allowsHitTesting(!infoMode)
        // Trap focus inside an open panel: while one is up, the transport buttons
        // drop out of the focus engine so directional nav can't wander out of the
        // menu. It closes only by selecting a row or pressing Menu (native-menu
        // behaviour). The scrub surface is already non-focusable while the bar owns
        // focus, so the open panel becomes the sole focusable region.
        //
        // The row stays focusable in `infoMode` even though it's invisible: that's
        // what lets Up from the Info tab walk back into it (and bring it back). Its
        // own focus section groups the buttons, so a directional move from the
        // leading-edge Info tab treats them as one region to aim at despite the
        // horizontal offset between them.
        .disabled(openPanel != nil)
        .plozzFocusSection()
        // The menus are anchored to this row, so the Speed button's leading edge is
        // measured in ITS space — the offset that aligns the Speed menu to its own
        // button is then just that number.
        .coordinateSpace(name: Self.trackControlsSpace)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TrackControlsWidthKey.self, value: proxy.size.width)
                    // GLOBAL, not the named controls space: the cluster carries an
                    // `.offset` for the Info reveal, and a named-space measurement is
                    // taken from the pre-transform layout, so the menus were placed
                    // against where the buttons WOULD be without it — landing on top
                    // of them. The global frame reflects the transform.
                    //
                    // Which is also why it's frozen while the card is up: reflecting
                    // the transform means this changes on EVERY frame of the reveal,
                    // and republishing it would rewrite @State (invalidating the whole
                    // body) ~30 times per reveal. Republishing the last value is a
                    // no-op for `onPreferenceChange`. Nothing is lost: no options menu
                    // can be open while the card is, so nobody reads it meanwhile.
                    .preference(
                        key: TrackControlsTopKey.self,
                        value: infoMode ? trackControlsTop : proxy.frame(in: .global).minY
                    )
            }
        )
        .onPreferenceChange(TrackControlsWidthKey.self) { trackControlsWidth = $0 }
        .onPreferenceChange(TrackControlsTopKey.self) { trackControlsTop = $0 }
    }

    /// True while the Info card owns the moment. The track controls and the scrub
    /// bar fade out then, leaving just the tab and its card, like the Apple TV app.
    ///
    /// Keyed on the card ALONE — not "card open *or* tab focused". Focus lands on
    /// the tab one update before the card opens, so including it made the rows start
    /// fading a frame before the card began to move: the desync that read as jank.
    /// (The tab can only be focused with the card open anyway — see
    /// `infoTabFocusable` — so this loses nothing.)
    private var infoMode: Bool {
        Self.usesBottomCard(openPanel)
    }

    /// Whether a category is shown in the bottom card rather than the floating
    /// options menu.
    ///
    /// The card is a permanent, fixed-height member of the stack — the reveal is
    /// one transform on a fixed stage, which is why nothing arrives on its own
    /// clock. A sibling tab therefore switches the card's *content*; it never
    /// mounts a second card, which would reflow the stage and break that.
    static func usesBottomCard(_ category: Category?) -> Bool {
        category == .info || category == .cast
    }

    /// `openPanel` with Info masked out, so the options panels' own animation can be
    /// keyed on it and stay clear of the Info reveal's clock.
    private var optionsPanel: Category? {
        // EVERY card tab is masked, not just Info. A card tab that leaks through
        // opens the floating menu on top of its own card — and that menu takes
        // focus, which is why the Cast faces could not be reached.
        Self.usesBottomCard(openPanel) ? nil : openPanel
    }

    /// The cluster's bottom margin: how far the tab row rests above the screen edge
    /// with the card closed. 48 sits a little inside the 54pt action-safe line and
    /// 12pt below tvOS's 60pt title-safe line — deliberately, to match where the
    /// Apple TV app puts its own transport.
    private static let bottomMargin: CGFloat = 48

    /// Gap between the tab row and the Info card when the card is open.
    ///
    /// Tighter than `bottomMargin`, which a perfectly rigid cluster can't do: parking
    /// it far enough to return the tab to that margin would leave the top
    /// `bottomMargin − gap` of the card showing. The shortfall is made up by
    /// `infoCardCatchUp` instead.
    private static let infoCardGap: CGFloat = 32

    /// The extra distance the card travels beyond the rest of the cluster, so a gap
    /// tighter than `bottomMargin` still parks it fully off-screen.
    ///
    /// This is a deliberate, measured break from "everything moves as one unit" —
    /// the rule that made the reveal read as a single object in the first place. It
    /// survives contact with the eye because of what is NOT broken: the card is
    /// driven by the same `infoMode` change, through the same spring, so it starts
    /// and LANDS with everything else. Only its speed differs, by
    /// `catchUp / totalTravel` — a couple of percent over ~300pt. What reads as
    /// desynchronised is parts arriving at different times, not parts covering
    /// slightly different distances together.
    private static var infoCardCatchUp: CGFloat { max(0, bottomMargin - infoCardGap) }

    /// The revealed card's inset from the screen on all three of its free edges.
    /// Equal to the side margin by definition, so the card reads as evenly framed
    /// rather than 12pt tighter at the bottom than at the sides.
    private static var infoCardInset: CGFloat { horizontalMargin }

    /// Extra bottom padding under the card, on top of the cluster's own margin, to
    /// reach `infoCardInset`.
    ///
    /// Free of charge: it drops out of the parking arithmetic entirely. Lifting the
    /// cluster by this much MORE still returns the tab to exactly `bottomMargin`, so
    /// the card can be framed evenly without the tab moving a pixel. (What can't
    /// change is the gap — see `infoCardGap`.)
    private static var infoCardBottomPad: CGFloat { max(0, infoCardInset - bottomMargin) }

    /// How far down the CLUSTER parks when the Info card is closed.
    ///
    /// The stack is permanently in its revealed arrangement, so parking has two jobs:
    /// return the tab to its resting height, and put the card off-screen. Writing
    /// H = `InfoPanelView.cardHeight` (258), pad = `infoCardBottomPad` (12),
    /// gap = `infoCardGap` (32), margin = `bottomMargin` (48), so lift = 302:
    ///
    ///   revealed  tab bottom = bottom − margin − pad − H − gap
    ///   parked    tab bottom = that + lift = bottom − margin        ✓ resting height
    ///
    ///   revealed  card top   = bottom − margin − pad − H
    ///   parked    card top   = that + lift = bottom + (gap − margin) = bottom − 16
    ///
    /// The card's top would therefore sit 16pt ABOVE the edge — the price of a gap
    /// tighter than the margin — so the card alone travels a further
    /// `infoCardCatchUp` (16) and lands exactly on it. See that constant for why the
    /// small differential doesn't read as desynchronised.
    ///
    /// A CONSTANT, deliberately. Deriving it from a measured height meant the parked
    /// offset changed the instant the measurement arrived — and again whenever the
    /// card's metadata did — teleporting the transport. `InfoPanelView` pins its own
    /// height, so this is exact.
    private static let infoCardLift: CGFloat =
        InfoPanelView.cardHeight + infoCardBottomPad + infoCardGap

    /// The single clock the Info card's arrival and departure run on.
    ///
    /// A spring, not an ease: the card is a physical thing being pushed up into the
    /// frame, and `.smooth` is the same family the series-detail hero reveal uses
    /// (`SeriesHeroRevealTransition.ambient`) — shorter here because this is one
    /// card, not a whole page.
    private static let infoReveal: Animation = .smooth(duration: 0.5)


    /// The tab row beneath the scrub bar. Today a single Info tab; siblings
    /// (Chapters, …) join it here and switch the card below rather than opening
    /// their own floating panel. Titled, not icon-only — these read as tabs.
    private var tabRow: some View {
        HStack(spacing: 20) {
            Button {
                toggle(.info)
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.titleOnly)
            }
            .buttonStyle(PlayerTabButtonStyle(focused: focus == .button(.info), selected: openPanel == .info))
            .focused($focus, equals: .button(.info))
            .disabled(!tabFocusable(.info))
            .onChange(of: focus) { _, slot in selectCardTab(focusedTo: slot) }

            // Hidden entirely when what is playing has no cast: a tab that opens
            // an empty card is worse than an absent one, and `.disabled` alone
            // would leave it visible but dead.
            if isTabVisible(.cast) {
                Button {
                    toggle(.cast)
                } label: {
                    Label(Category.cast.title, systemImage: Category.cast.icon)
                        .labelStyle(.titleOnly)
                }
                .buttonStyle(PlayerTabButtonStyle(focused: focus == .button(.cast), selected: openPanel == .cast))
                .focused($focus, equals: .button(.cast))
                .disabled(!tabFocusable(.cast))
            }

            Spacer(minLength: 20)
        }
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .allowsHitTesting(!model.isScrubbing)
        // The exit strip rides along as an overlay so it adds no layout of its own.
        .overlay(alignment: .top) { infoExitGuide }
        // The tab is in the focus order ONLY while its card is open (or is opening,
        // on a Down entry). That's the invariant — focused tab == visible card —
        // made structural: with the card closed the engine simply cannot move onto
        // the tab, so Down from a track control can't land there and the tab can
        // never sit focused over nothing. `PlayerTabButtonStyle` ignores
        // `\.isEnabled`, so this removes the tab from the focus order WITHOUT
        // greying it out.
        // Bridge the horizontal offset between the rows: the track controls sit at
        // the trailing edge and the tab at the leading one, so nothing is
        // geometrically below Speed/Audio/Subtitles and a Down press would simply do
        // nothing. The row spans the full width (button + Spacer) and is its own
        // focus section, so Down from ANY track button routes into it — the same
        // trick the Info card uses for its Playback Info button.
        .frame(maxWidth: .infinity, alignment: .leading)
        .plozzFocusSection()
    }

    /// The one control allowed to hold focus while an entry is in flight, or nil
    /// once the entry has settled and ordinary navigation resumes.
    ///
    /// The focus engine decides where focus lands when the control layer becomes
    /// focusable, and it does NOT defer to a `@FocusState` value that is already in
    /// place — telemetry caught it moving focus off our intended button. So rather
    /// than steering the engine, we narrow what it can choose from: for the couple
    /// of frames an entry takes, every control except the entry's own target leaves
    /// the focus order, and the engine's pick is correct because it is the only pick
    /// available. Down targets the Info tab (its card is the destination); Up
    /// targets the first track control.
    private var entryFocusTarget: FocusSlot? {
        guard model.controlBarVisible, !model.controlBar.settled else { return nil }
        guard model.controlBar.entry == .info else { return initialFocus }
        let tab = Self.usesBottomCard(parkedCardTab) && isTabVisible(parkedCardTab)
            ? parkedCardTab
            : .info
        return .button(tab)
    }

    /// Whether `slot` is held out of the focus order for the duration of an entry.
    /// The window is a couple of frames and coincides with the transport fading in,
    /// so nothing settled is on screen to look dimmed.
    private func entryLocksOut(_ slot: FocusSlot) -> Bool {
        guard let target = entryFocusTarget else { return false }
        return slot != target
    }

    /// Whether the Info tab is in the focus order: only while its card is open, or
    /// while a Down entry is on its way to opening it. See the tab's `.disabled`.
    private func tabFocusable(_ tab: Category) -> Bool {
        // Out of the focus order entirely while a cast drill is in flight.
        //
        // Opening and closing a person's details each leave a moment with
        // nothing focusable in the card, and the engine parks on the nearest
        // candidate — a tab. Re-asserting focus afterwards corrects it, but the
        // viewer sees the tab light up first, which reads as a stutter.
        // Removing the tabs as candidates means the engine cannot choose them in
        // the first place, so there is nothing to correct.
        if isRestoringCastRow { return false }
        // Any card tab is reachable while the card is open, so Left/Right moves
        // between them. The invariant that matters is unchanged and still
        // structural: with the card CLOSED no tab is in the focus order, so a Down
        // press from a track control cannot land on one and no tab can sit focused
        // over nothing.
        // During an entry the target tab is the ONLY focusable one, even though
        // its card is already open — the reveal and the entry overlap, and
        // without this the other tab was a candidate mid-reveal.
        if let entryFocusTarget { return entryFocusTarget == .button(tab) }
        if Self.usesBottomCard(openPanel) {
            guard isTabVisible(tab) else { return false }
            // A tab OTHER than the open one is reachable only from the tab row
            // itself, never from inside the card.
            //
            // Up from a face moves to whatever sits nearest above it, and the
            // first card is directly under the Info tab — so Up from the first
            // face landed on Info and switched tabs, while every other face
            // correctly reached Cast. Narrowing the choice means the open tab is
            // the only candidate from inside the card, and its neighbour is
            // still one Left/Right away once focus is on the row.
            if tab != openPanel, !isFocusOnTabRow { return false }
            return true
        }
        return entryFocusTarget == .button(tab)
    }

    /// Whether focus is on the tab row rather than inside the card below it.
    private var isFocusOnTabRow: Bool {
        if case .button? = focus { return true }
        return false
    }

    /// Cast hides itself when what is playing has no cast to show — a tab that
    /// opens an empty card is worse than an absent one.
    private func isTabVisible(_ tab: Category) -> Bool {
        tab == .cast ? !model.infoCard.cast.isEmpty : true
    }

    /// The floating options menu (Speed · Audio · Subtitles), including the Subtitle
    /// Style editor it morphs into.
    ///
    /// ONE panel whose position flips between two anchors — not two panels swapping
    /// places. That is what restores the original tracks↔Style transition: the
    /// container travels up and grows in a single continuous morph, instead of one box
    /// vanishing as another appears. Splitting them in order to pin Style at the top
    /// is what lost it; both behaviours are wanted, and this gives both.
    ///
    /// The travel animates because the panel's IDENTITY never changes — only the
    /// `Spacer`s around it come and go, and a Spacer's length animates. (Putting the
    /// panel itself in an `if/else` would give the branches separate identities and
    /// hard-cut between them. The original avoided that the same way, by flipping
    /// Spacers around a fixed cluster.)
    @ViewBuilder
    private var optionsPanelLayer: some View {
        if let panel = optionsPanel {
            VStack(spacing: 0) {
                // Style pins to the TOP, so its height changes extend downward and
                // walking into a sub-screen can neither shift the panel nor overflow
                // the screen. Every other menu rests just above the buttons that
                // opened it.
                if !styleEditing { Spacer(minLength: 0) }
                morphingPanel(for: panel)
                    .plozzFocusSection()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    // Horizontal placement, measured LEFTWARD from the trailing edge.
                    .offset(x: -panelTrailingShift(for: panel))
                if styleEditing { Spacer(minLength: 0) }
            }
            .padding(.horizontal, Self.horizontalMargin)
            .padding(.top, Self.horizontalMargin)
            // Rest just above the track controls. Their top edge is MEASURED rather
            // than derived from the transport's height: the buttons are one row inside
            // it, and that row's height is set by the much taller title block beside
            // them.
            // Only the bottom-anchored menus reserve room above the buttons. The Style
            // editor is top-pinned, so that inset is dead space below it — and a tall
            // sub-screen (Font) plus 315pt of it exceeded the layer's height, growing
            // the ZStack and nudging every child, cluster included. That showed up as
            // the submenu drifting down and the Info card peeking in from the bottom.
            .padding(.bottom, styleEditing ? Self.horizontalMargin : menuBottomInset)
            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    /// Distance from the bottom of the controls layer up to the top of the track
    /// controls, plus the gap a menu leaves above them. Falls back to the transport's
    /// measured height until the first measurement lands.
    private var menuBottomInset: CGFloat {
        guard controlsBottom > 0, trackControlsTop > 0, controlsBottom > trackControlsTop else {
            return transportHeight + Self.bottomMargin + Self.panelLift
        }
        // BOTH edges in global space. The layer is inset by the tvOS safe area, so its
        // height (960) is 60pt short of its bottom edge (1020) — subtracting the
        // buttons' global top from the layer's HEIGHT put every menu 60pt too low,
        // landing it on the buttons it belongs above.
        return controlsBottom - trackControlsTop + Self.panelLift
    }

    /// A thin focusable strip just above the Info tab, present only while the card
    /// is open. It is the *destination* of an Up press from the tab — and focusing
    /// it closes the card (see `onChange(of: focus)`).
    ///
    /// Why a target rather than reading the press: with the card open, everything
    /// above the tab is out of the focus order, so tvOS delivers the Up press and
    /// any focus change it causes in an order that isn't guaranteed. Interpreting
    /// the press therefore couldn't tell "Up ON the tab" from "Up that MOVED me to
    /// the tab", and Up from a card button skipped the tab and dropped to the scrub
    /// bar. Giving the gesture somewhere to LAND lets the focus engine answer the
    /// question instead: from a card button the tab is nearer, so focus stops there;
    /// only from the tab itself is this the next thing up.
    ///
    /// The usual caveat about invisible focus catchers (they lose proximity contests
    /// — see `FocusGatedSwitch`) doesn't bite here: while the card is open this is
    /// the ONLY focusable thing above the tab, so it has no competition.
    @ViewBuilder
    private var infoExitGuide: some View {
        if infoExitGuideActive {
            // Not `Color.clear`: UIKit won't focus a fully transparent view.
            Color.black.opacity(0.001)
                .frame(height: 8)
                .frame(maxWidth: .infinity)
                .focusable()
                .focused($focus, equals: .infoExit)
                .offset(y: -26)
        }
    }

    /// Whether the exit strip is currently in the focus order.
    ///
    /// It exists only once focus is already somewhere in the Info region — never
    /// while focus is arriving. Focusing the strip MEANS "leave the card", so during
    /// a Down entry it was a trap: it appeared the instant the card opened, the focus
    /// engine's entry pass picked it (nothing else sits that high), and the reveal
    /// closed itself — a Down press that bounced straight back to the scrub bar.
    /// Requiring focus to already be on the tab or a card button means the strip can
    /// only ever be reached deliberately, by pressing Up from inside the card.
    private var infoExitGuideActive: Bool {
        // ANY card tab, not just Info. The strip is what Up presses against to
        // leave the card, and it was gated on the Info panel alone — so from the
        // Cast tab there was simply nothing above to move onto and Up did
        // nothing. The Cast card's own contents are excluded deliberately: Up
        // from a face belongs to the row, which hands focus back to the tab.
        guard Self.usesBottomCard(openPanel), model.controlBar.settled else { return false }
        // Never while a person's details are open — Up there is the drill's own
        // business, and leaving the whole card mid-detail would strand it.
        if castDetailPerson != nil { return false }
        switch focus {
        case .button(.info), .button(.cast),
             .infoNext, .infoPrev, .infoRestart, .infoStats:
            return true
        default:
            return false
        }
    }

    /// The now-playing card the Info tab reveals, full width beneath the tab row.
    /// What the bottom card is showing.
    ///
    /// One card, switched content — never two cards. The stage is fixed and the
    /// reveal is a single transform over it, so mounting a second card would
    /// reflow the layout and the transport would jump. Both panels are therefore
    /// sized to `InfoPanelView.cardHeight`.
    ///
    /// The Cast panel stays mounted while Info is showing (and vice versa) only in
    /// the sense that the *card* does; the inactive panel is not built, because
    /// its focusable faces would otherwise join the focus order behind the visible
    /// one.
    @ViewBuilder
    private var cardContent: some View {
        if parkedCardTab == .cast {
            // Deliberately NOT clipped, unlike Info. The cast row is a set of
            // separate cards that GROW on focus, and clipping to the stage sliced
            // the lift — the leading card lost its outline and part of itself
            // against the left edge. It can go unclipped because it is never the
            // parked content: closing sets `openPanel` to nil, which swaps this
            // branch out before the card travels off-screen, so the shadow that
            // forces Info's clip can never escape here.
            CastPanelView(
                model: model,
                focus: $focus,
                detailPerson: $castDetailPerson,
                closeRequest: $castCloseRequest,
                isCardOpen: infoMode,
                revealClock: revealClock
            )
                .onChange(of: castDetailPerson) { _, _ in
                    // BOTH directions. Opening disables the row so its faces
                    // leave the focus order, and closing removes the detail —
                    // either way there is a moment with nothing focusable in the
                    // card, and the engine parks on the Info tab, whose
                    // focus rule then opens the Info card. Guarding only the
                    // close left opening broken in exactly the same way.
                    isRestoringCastRow = true
                    Task { @MainActor in
                        // Two hops: the first lets the row be built, the second
                        // lets the focus engine run its pass over it.
                        // Long enough to outlast the press that started this —
                        // a couple of runloop turns is not enough, because the
                        // stray activation arrives with the touch-up event.
                        // Just long enough for the pane to be built or removed
                        // and the engine to settle; the tabs are unreachable for
                        // this whole window, so nothing can grab focus in it.
                        try? await Task.sleep(for: .milliseconds(220))
                        isRestoringCastRow = false
                    }
                }
        } else {
            // Clip to the card's own silhouette. Liquid Glass draws a soft shadow
            // beyond the shape it's applied to, and that shadow was escaping the
            // strip masked off at the bottom of the screen — so the card announced
            // itself with a glow above the bottom edge while still closed. (Losing
            // the shadow is no loss here: the panels deliberately don't use one, a
            // per-frame offscreen blur over Dolby Vision being the original
            // frame-drop culprit. See `PanelGlassBackground`.)
            InfoPanelView(model: model, actions: actions, focus: $focus, onClose: closeInfoCard)
                .clipShape(RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
                    style: .continuous
                ))
        }
    }

    private var infoCard: some View {
        cardContent
            .colorScheme(.dark)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Move between card tabs by *moving focus*, with no press needed — the
    /// behaviour of the season bar on the detail page, and what a row of tabs
    /// implies. Only ever switches between already-open card tabs: it must not
    /// open the card, since focus can be on a tab during a Down entry before the
    /// viewer has chosen anything.
    private func selectCardTab(focusedTo slot: FocusSlot?) {
        guard !isRestoringCastRow,
              Self.usesBottomCard(openPanel),
              case let .button(tab)? = slot,
              Self.usesBottomCard(tab),
              tab != openPanel
        else { return }
        // No `withAnimation`: the card is already revealed, so this is a content
        // swap. Replaying the reveal would slide the card out and back.
        parkedCardTab = tab
        openPanel = tab
    }

    private func toggle(_ category: Category) {
        // A card tab cannot be activated while the cast row is coming back.
        //
        // Backing out of a person's details destroys the Back button MID-PRESS.
        // Focus falls to the nearest candidate — the Info tab — and the press
        // completes on THAT, so the viewer's single Select both closed the
        // details and silently switched tabs. The trace showed the panel already
        // changed before `selectCardTab` was even consulted, which is what ruled
        // that path out as the cause.
        if isRestoringCastRow, Self.usesBottomCard(category) {
            return
        }
        if openPanel == category {
            // Closing the Info card also gives up the tab (they're one unit); every
            // other panel just hands focus back to the button that opened it.
            if Self.usesBottomCard(category) {
                closeInfoCard()
            } else {
                openPanel = nil   // focus restoration handled centrally in onChange(of: openPanel)
            }
        } else if Self.usesBottomCard(category) {
            // Switching BETWEEN card tabs must not re-run the reveal: the card is
            // already up, and replaying the transform would slide it out and back
            // for a content swap. Only an opening from closed animates.
            if Self.usesBottomCard(openPanel) {
                parkedCardTab = category
                openPanel = category
                focus = .button(category)
            } else {
                panelReturnFocus = focus ?? .button(category)
                revealInfoCard(category)
            }
        } else {
            panelReturnFocus = focus ?? .button(category)
            openPanel = category
        }
    }

    /// Move focus programmatically after the current view update settles.
    ///
    /// Both opening and closing a panel provoke tvOS's focus engine to run its own
    /// default/auto-recovery pass in the same update: on close the focused row is
    /// removed and the engine recovers to the leftmost transport control; on open the
    /// panel's rows appear while the opening button is disabled, forcing the engine to
    /// pick a default (the section's first row). Writing @FocusState synchronously
    /// races that pass (and writing it *twice* — sync + deferred — briefly renders two
    /// controls focused). A SINGLE deferred write on the next runloop tick runs after
    /// the engine settles, so it lands cleanly: on open it reaches the active row, on
    /// close it returns focus to whichever control opened the panel — no matter how
    /// deep its sub-screens went.
    private func restoreFocus(_ slot: FocusSlot?) {
        guard let slot else { return }
        DispatchQueue.main.async { focus = slot }
    }

    /// The focus target a freshly-opened panel should land on: the active/selected
    /// row for the track lists, the first available delay row for Sync, the tab
    /// itself for Info, and the right control for each Subtitles sub-screen. Deferred
    /// onto `focus` in `onChange(of: openPanel)` via `restoreFocus`.
    private var preferredPanelFocus: FocusSlot? {
        guard let panel = openPanel else { return nil }
        switch panel {
        case .info, .cast:
            // The tab, not the card: the row above the card behaves like a
            // segmented control, so opening lands there and a further Down press
            // steps into the card's actions.
            return .button(panel)
        case .subtitles:
            switch subtitleScreen {
            case .tracks:
                return .row(selectedRowIndex(for: .subtitles))
            case .download:
                // Land on the first result when we have them; while still searching
                // (no rows yet) rest on Back. An async results arrival is handled by
                // an onChange that moves focus onto the first row.
                if case .results = model.subtitleDownload.state { return .row(0) }
                return .subBack
            case .sync:
                // Land on the − nudge (leftmost control); the value and + sit to
                // its right.
                return .row(0)
            case .style:
                return model.secondarySubtitleImagePrimaryFormat == nil ? .row(0) : .subBack
            case .styleFont:
                return .row(SubtitleFontFamily.allCases.firstIndex(of: model.subtitleStyle.fontFamily) ?? 0)
            case .styleOutline, .styleBackground, .styleDual:
                return .row(0)
            }
        case .audio, .speed:
            return .row(selectedRowIndex(for: panel))
        case .sync:
            if model.engineCapabilities.contains(.audioDelay) { return .row(0) }
            if model.engineCapabilities.contains(.subtitleDelay) { return .row(10) }
            return nil
        }
    }

    // MARK: Panels

    /// Fixed width for an open control panel, per category. Most menus share a
    /// roomy 520pt column; the Speed menu only holds short preset labels
    /// ("1.25×") and a compact stepper, so it uses roughly half the width to
    /// avoid a mostly-empty panel.
    private func panelWidth(for category: Category) -> CGFloat {
        switch category {
        case .speed: return 260
        // The Download screen lists scene-release filenames; it's wider than the
        // other menus, and the title marquee-scrolls the rest on focus, so it needs
        // room to be readable without being absurdly wide.
        case .subtitles where subtitleScreen == .download: return 860
        default: return 520
        }
    }

    /// How far LEFT of the button row's trailing edge a menu sits.
    ///
    /// Zero for the wide menus (Audio / Subtitles / Sync): they hang off that trailing
    /// edge, growing leftward, which is what keeps them on screen — they are wider than
    /// the row they're anchored to. Speed instead lines up with its own button, so it
    /// shifts left by however far that button is from the trailing edge, and is clamped
    /// so a menu wider than the remaining space can't push back out past the edge.
    private func panelTrailingShift(for category: Category) -> CGFloat {
        guard category == .speed, trackControlsWidth > 0 else { return 0 }
        let fromTrailing = trackControlsWidth - speedButtonLeading
        return max(0, fromTrailing - panelWidth(for: category))
    }

    /// The tallest a scrollable list (track list / Audio / Speed / Sync) may grow
    /// before it clamps + scrolls, so a long list never overflows. The Style editor
    /// is exempt — it grows to its full natural height.
    private static let panelBodyMaxHeight: CGFloat = 440

    /// The floating options panel for every non-info category. A *single*
    /// measured-height container (no per-screen swap), so navigating between screens
    /// — the track list, the Style editor, and its sub-screens — animates ONLY the
    /// glass box's height while the rows stay put:
    ///
    /// - The body is laid out inside a `ScrollView` and its natural height measured
    ///   via `PanelBodyHeightKey`; that value drives the box height, animated in
    ///   `onPreferenceChange` (a plain `.animation(_, value:)` doesn't reliably fire
    ///   for preference-driven state — it settles a frame after layout).
    /// - The Style editor (and sub-screens) is pinned to the top corner with room to
    ///   spare, so it grows to full natural height with scrolling disabled — the
    ///   morph reveals the rows top-down through the clip and nothing is cut off. The
    ///   track / Audio / Speed / Sync lists clamp to `panelBodyMaxHeight` and scroll.
    /// - Because the track list and the Style editor share this one container, tapping
    ///   Edit *morphs* the box height from the track-list height up to the Style
    ///   height instead of swapping one panel for another (which read as a jump).
    /// A separator matched to the surface it is drawn on.
    ///
    /// Replaces `Divider().background(...)`, which draws TWO things: the
    /// system divider and a white wash behind it. Over glass the refraction hid
    /// the doubling; over frost, which is lighter and flat, it read as a
    /// brighter, thicker line than the panel's own edge — the same idea at two
    /// different weights on one surface.
    private var frostAwareDivider: some View {
        // HDR-compensated like the borders, and for the same reason: this sits
        // inside the panel whose edge it has to match, and both are drawn into a
        // signal that maps SDR white brighter than SDR mode does.
        PlozzFrostedSurface.dividerColor(hdrDisplayActive: hdrDisplayActive)
            .frame(height: PlozzFrostedSurface.dividerHeight)
    }

    @ViewBuilder
    private func morphingPanel(for category: Category) -> some View {
        let styleFamily = category == .subtitles && subtitleScreen.isStyleFamily
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(for: category)
            frostAwareDivider
            morphingBody(styleFamily: styleFamily, category: category) { panelBodyContent(for: category) }
        }
        // Hard-swap the panel chrome + content on the tracks↔Style flip instead of
        // cross-fading it. `styleEditing` toggles ONLY on tracks→Style, and the
        // ambient `.animation(.easeInOut, value: styleEditing)` up in `body` would
        // otherwise capture this content-identity change and dissolve the track list
        // into the Style editor: the header title ("Subtitles"→"Subtitle Style") and
        // the rows ghost over each other, and the taller editor spills past the
        // still-growing box. Nil-ing animation for styleEditing-driven changes on the
        // whole panel makes header + rows swap instantly — exactly how the Style
        // *sub-screen* morphs already behave (they don't flip styleEditing, so they
        // never cross-fade). Only the box height then animates, via the explicit
        // `withAnimation` in `onPreferenceChange`: "animate the container, not what's
        // inside." The Spacer/transport layout flip keeps its animation (that modifier
        // lives on `body`, above this override).
        .animation(nil, value: styleEditing)
        // Content swaps INSTANTLY on a subtitle sub-screen change (track list ↔
        // Download ↔ Style): only the glass container should animate, never the rows
        // ghosting into each other. The container's width/height animate via the
        // explicit `withAnimation` in `openSubtitleScreen` + the height morph in
        // `onPreferenceChange` — both of which sit OUTSIDE this nil scope.
        .animation(nil, value: subtitleScreen)
        .frame(width: panelWidth(for: category), alignment: .leading)
        .colorScheme(.dark)
        .modifier(PanelGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        // Drive the height change explicitly (see note above). The first
        // measurement for a given panel snaps in (no grow-from-zero / no
        // shrink-from-stale); later changes *within the same panel* (the
        // tracks↔Style morph) animate.
        .onPreferenceChange(PanelBodyHeightKey.self) { heights in
            // Only ever read the currently-open panel's own height. A closing panel
            // keeps reporting its (tall) height through its 0.2s exit transition; by
            // keying on category we ignore it entirely instead of letting it size the
            // panel that's replacing it.
            guard let panel = openPanel,
                  let newHeight = heights[panel],
                  newHeight > 0,
                  newHeight != styleBodyHeight
            else { return }
            // Remember this panel's natural height so the next open can seed it and skip
            // the pre-measure→measured swap (see cachedPanelHeight). For Subtitles only
            // cache the tracks-list height — a fresh open always starts on the track list,
            // so we must not seed it with the taller Style-editor height.
            if panel != .subtitles || subtitleScreen == .tracks {
                cachedPanelHeight[panel] = newHeight
            }
            if measuredPanel != panel {
                // First measurement for THIS panel → snap to its natural size.
                // This write runs *inside* the ambient `.animation(value: openPanel)`
                // transaction that opening the panel started, so without explicitly
                // disabling animations the height correction would be interpolated and
                // the box would visibly resize on open. Disable animation for the snap
                // only; the tracks↔Style morph below keeps its explicit animation.
                measuredPanel = panel
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { styleBodyHeight = newHeight }
            } else {
                // Same panel, content morphed (tracks↔Style) → animate the box.
                withAnimation(.easeInOut(duration: 0.28)) { styleBodyHeight = newHeight }
            }
        }
    }

    @ViewBuilder
    private func morphingBody<Content: View>(
        styleFamily: Bool,
        category: Category,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = VStack(alignment: .leading, spacing: 0) {
            content()
        }
        // Equal top/bottom gutter so the first/last row's focus card sits the same
        // distance from the panel edge as its left/right gutter (18) — see the row
        // style's concentric card inset.
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PanelBodyHeightKey.self,
                    value: [category: proxy.size.height]
                )
            }
        )

        if styleBodyHeight > 0 {
            ScrollView {
                body
            }
            .scrollIndicators(.hidden)
            // The Style editor never scrolls (it grows to full height); disabling
            // scroll keeps the height morph a clean top-down clip reveal with no
            // bounce.
            .scrollDisabled(styleFamily)
            .frame(
                height: styleFamily ? styleBodyHeight : min(styleBodyHeight, Self.panelBodyMaxHeight),
                alignment: .top
            )
        } else {
            // Pre-measurement (first frame of a fresh open — always the track list,
            // as the Style editor is only reached from it). Render the body as a plain
            // VStack clamped to the cap.
            //
            // CRITICAL: a flexible `.frame(maxHeight:)` is GREEDY — given a tall
            // proposal (the bottom cluster proposes far more than the cap) it fills to
            // the cap regardless of content, so a 2-row Audio menu would paint at 440
            // and then shrink to its real ~166 once measured. Wrapping it in an outer
            // `.fixedSize(vertical:)` feeds the frame a nil proposal, so it falls back
            // to the child's ideal height clamped to the cap = min(content, cap). Now
            // the first painted frame equals the settled measured height for BOTH a
            // short list (→ its natural height) and a long 30-track list (→ the cap),
            // leaving zero height delta to animate on open.
            // The GeometryReader still reports the true content height for the handoff
            // to the scrolling branch, which enables scrolling for over-cap lists.
            body
                .frame(maxHeight: Self.panelBodyMaxHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        }
    }

    @ViewBuilder
    private func panelBodyContent(for category: Category) -> some View {
        switch category {
        case .subtitles: subtitleBody
        case .audio: AudioPaneView(rows: audioRows, palette: palette, focus: $focus)
        case .speed: SpeedPaneView(model: model, palette: palette, actions: actions, focus: $focus)
        case .sync: SyncPaneView(model: model, actions: actions, focus: $focus)
        // Card tabs render in the bottom card, never in the floating menu.
        case .info, .cast: EmptyView()
        }
    }

    /// Whether the transport's chrome (title, buttons, scrub bar, tab) hides itself,
    /// leaving the live subtitles clear behind the full-height appearance editor.
    ///
    /// Each piece applies this to ITSELF rather than the block applying one fade:
    /// the menus are an overlay on the buttons, and an ancestor's opacity multiplies
    /// through a subtree's overlays with no way to opt out — so a block-level fade
    /// took the open Style editor down with it.
    private var chromeHidden: Bool { styleEditing }

    /// True while the ✎ Edit appearance editor (or one of its detail sub-screens)
    /// is open. In this mode we hide the transport chrome and dim gradient and pin
    /// the content-sized panel to the top-right corner, so the live subtitles
    /// behind and beside it are unobstructed and every tweak is easy to see.
    private var styleEditing: Bool {
        openPanel == .subtitles && subtitleScreen.isStyleFamily
    }

    /// Header of the floating panel: the screen title, plus — on the Subtitles
    /// track list — a trailing ✎ Edit (appearance) button, and — on a Subtitles
    /// sub-screen — a leading Back chevron.
    @ViewBuilder
    private func panelHeader(for category: Category) -> some View {
        HStack(spacing: 14) {
            // On a Subtitles sub-screen (Style / Download), the Back control lives
            // in the header — leading the title — so it mirrors the other menus
            // rather than floating inside the scrollable content.
            if category == .subtitles && subtitleScreen != .tracks {
                Button {
                    openSubtitleScreen(subtitleScreen.parent)
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(PlozzPanelHeaderButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .subBack)
                // Pull the chip past the header gutter so it hugs the panel's
                // leading edge, concentric with the rounded corner.
                .padding(.leading, -10)
            }
            Text(headerTitle(for: category))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if category == .subtitles && subtitleScreen == .tracks {
                // Timing (Sync) chip — only when the app's overlay owns the active
                // subtitle, so the app-side offset can actually shift it. Sits left
                // of Style; opens a compact delay screen. Icon-only (clock) so the
                // header fits the title plus both chips.
                if model.subtitleDelayAdjustable {
                    Button {
                        openSubtitleScreen(.sync)
                    } label: {
                        Image(systemName: "clock")
                            .accessibilityLabel("Subtitle Sync")
                    }
                    .buttonStyle(PlozzPanelHeaderButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .subSync)
                }
                Button {
                    openSubtitleScreen(.style)
                } label: {
                    Label("Style", systemImage: "paintpalette")
                }
                .buttonStyle(PlozzPanelHeaderButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .edit)
                // Mirror the back chip: hug the trailing edge, ignoring the gutter.
                .padding(.trailing, -10)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 18)
        // Group the header as a focus section so directional focus can reach it
        // from anywhere below — e.g. pressing Up from the right (+) chip of the
        // sync stepper lands on Back even though nothing is geometrically above it.
        .plozzFocusSection()
    }

    private func headerTitle(for category: Category) -> LocalizedStringResource {
        guard category == .subtitles else { return category.title }
        switch subtitleScreen {
        case .tracks: return category.title
        case .download: return LocalizedStringResource(
            "player.subtitles.download",
            defaultValue: "Download Subtitles",
            comment: "Header of the in-player screen for downloading subtitle files."
        )
        case .sync: return LocalizedStringResource(
            "player.subtitles.sync",
            defaultValue: "Subtitle Sync",
            comment: "Header of the in-player screen for adjusting subtitle timing."
        )
        case .style: return "Subtitle Style"
        case .styleFont: return "Font"
        case .styleOutline: return "Shadow & Outline"
        case .styleBackground: return "Background"
        case .styleDual: return "Dual Subtitles"
        }
    }

    /// The Subtitles panel is a small master flow: the track list (default), a
    /// Download screen (from the trailing row) and a Style screen (from ✎ Edit).
    @ViewBuilder
    private var subtitleBody: some View {
        switch subtitleScreen {
        case .tracks: subtitlePane
        case .download:
            // Pin the Download screen to the panel's max body height so it opens to a
            // stable size and stays put across its states (searching → results →
            // downloading → added). Without this floor the short "searching"/"added"
            // states would collapse the box and the results list would then grow it
            // back — a visible shrink-then-expand. A tall results list still scrolls
            // (the enclosing morphingBody caps + scrolls at this same height).
            SubtitleDownloadScreen(model: model, actions: actions, focus: $focus)
                .frame(minHeight: Self.panelBodyMaxHeight, alignment: .top)
        case .sync: SubtitleSyncScreen(model: model, actions: actions, focus: $focus)
        case .style, .styleFont, .styleOutline, .styleBackground, .styleDual:
            SubtitleStylePanel(
                screen: subtitleScreen,
                model: model,
                palette: palette,
                actions: actions,
                focus: $focus,
                openScreen: { openSubtitleScreen($0) }
            )
        }
    }

    /// The Subtitles track list: one full-width column of selectable tracks
    /// (incl. "Off"), then a trailing "Search for subtitles…" row. Full width so
    /// a rich label ("Spanish (SDH, PGS)") never truncates.
    @ViewBuilder
    private var subtitlePane: some View {
        VStack(alignment: .leading, spacing: 2) {
            let rows = subtitleRows
            if rows.isEmpty {
                emptyRow("No subtitles")
            } else {
                PlayerMenuRowStack(rows: rows, palette: palette, focus: $focus)
            }
            frostAwareDivider
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            if model.subtitleDownload.canSearch {
                downloadEntryRow
            }
            #if DEBUG
            if !model.subtitleDownload.primaryDiagnostic.isEmpty {
                Text(model.subtitleDownload.primaryDiagnostic)
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
            }
            #endif
        }
        .padding(.horizontal, 14)
    }

    /// "Looked through them all, found nothing → get more." Kept at the END of
    /// the list so it surfaces exactly when it's needed (few / no tracks) and
    /// stays out of the way when there are many.
    private var downloadEntryRow: some View {
        Button {
            openSubtitleScreen(.download)
            // Kick off a search on entry (idempotent: while results already show,
            // re-opening won't wipe them — the VM only re-searches on demand).
            if case .results = model.subtitleDownload.state {} else {
                actions.searchRemoteSubtitles(nil)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.body)
                Text("Download subtitles…").font(.body).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .download)
    }

    private func openSubtitleScreen(_ screen: SubtitleScreen) {
        // Entering the Style editor from the (non-style) track list flips the body
        // from the capped, scrollable list to the UNCAPPED Style column. At this point
        // `styleBodyHeight` still holds the track list's full measured content height,
        // which for a film with ~60 language tracks is ~2000pt — far past the cap it
        // was actually displayed at. Uncapping without clamping would snap the box to
        // that stale height and then shrink it down to the ~700pt editor: a violent
        // overshoot (invisible on short lists, where the stale height already ≈ the
        // editor height). Clamp the morph baseline to the height the list was really
        // showing so the box grows cleanly from the cap up to the editor instead of
        // collapsing into it from far above. The snap is un-animated; the subsequent
        // grow to the editor's true height animates via `onPreferenceChange`.
        if !subtitleScreen.isStyleFamily && screen.isStyleFamily {
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                styleBodyHeight = min(styleBodyHeight, Self.panelBodyMaxHeight)
            }
        }
        // Animate the CONTAINER as the screen changes: setting `subtitleScreen`
        // inside an explicit animation animates the frame width (e.g. 520→720 for
        // the wider Download screen) and, via onPreferenceChange, the height. The
        // content is held instant by `.animation(nil, value: subtitleScreen)` on the
        // panel, so only the glass box glides; the rows swap without ghosting.
        withAnimation(.easeInOut(duration: 0.28)) {
            subtitleScreen = screen
        }
        // Defer the focus write to the next runloop tick (same mechanism as
        // panel-open, via `restoreFocus`). Swapping the header chips + rows for the
        // new sub-screen makes tvOS's focus engine run its own default pass in this
        // same update; a synchronous @FocusState write races it and the engine wins —
        // landing on the header Back chip instead of the intended row (e.g. Font at
        // the top of the Style editor). `preferredPanelFocus` already encodes the
        // correct target for every sub-screen, so reuse it.
        restoreFocus(preferredPanelFocus)
    }

    /// The Audio menu: one full-width column of selectable tracks plus the
    /// Dialog Enhance toggle when the engine supports it.
    // MARK: Rows

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .plozzForeground(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
    }

    // MARK: Model helpers

    /// Focus target when the track row first takes focus: its FIRST control, i.e.
    /// the leading edge of the row. (It used to prefer Subtitles as "the most-used
    /// control", which read as arbitrarily skipping past Speed and Audio.)
    private var initialFocus: FocusSlot {
        guard let first = model.trackControlCategories.first else { return .button(.info) }
        return .button(first)
    }

    struct TrackRow: Identifiable {
        let id: Int
        let header: Text?
        let title: Text
        /// `nil` means the row has no second line (previously spelled as an empty
        /// string, which Text can't express).
        let subtitle: Text?
        let isSelected: Bool
        let isToggle: Bool
        var isExternal: Bool = false
        let action: () -> Void
    }

    /// Subtitle menu rows (one full-width column, including "Off"). Indexed from
    /// 0 in their own focus-slot space — safe because only one panel is open at a
    /// time, so audio and subtitle `.row` ids never coexist.
    private var subtitleRows: [TrackRow] {
        guard model.hasSelectableSubtitles else { return [] }
        return model.subtitleOptions.enumerated().map { index, option in
            TrackRow(
                id: index,
                header: nil,
                title: option.title,
                subtitle: nil,
                isSelected: option.isSelected,
                isToggle: false,
                isExternal: option.isExternal,
                action: { actions.selectSubtitle(option.id) }
            )
        }
    }

    /// Audio menu rows: selectable tracks followed by the Dialog Enhance toggle
    /// when supported. Indexed from 0 in their own focus-slot space. Every audio
    /// track is listed even when there's only one, so the menu always reflects
    /// what's playing.
    private var audioRows: [TrackRow] {
        var rows: [TrackRow] = []
        var index = 0
        for option in model.audioOptions {
            rows.append(TrackRow(
                id: index,
                header: nil,
                title: option.title,
                subtitle: nil,
                isSelected: option.isSelected,
                isToggle: false,
                action: { actions.selectAudio(option.id) }
            ))
            index += 1
        }
        if model.engineCapabilities.contains(.dialogEnhance) {
            rows.append(TrackRow(
                id: index,
                header: nil,
                title: Text("Dialog Enhance"),
                subtitle: Text("Boost speech clarity in loud mixes"),
                isSelected: model.dialogEnhanceEnabled,
                isToggle: true,
                action: { actions.setDialogEnhance(!model.dialogEnhanceEnabled) }
            ))
            index += 1
        }
        return rows
    }

    private func selectedRowIndex(for category: Category) -> Int {
        switch category {
        case .subtitles:
            // Open focused on the active subtitle (incl. "Off"), else the top row.
            return subtitleRows.first(where: { $0.isSelected })?.id ?? 0
        case .audio:
            return audioRows.first(where: { $0.isSelected })?.id ?? 0
        case .speed:
            return Self.speedPresets.firstIndex(where: { abs(model.playbackSpeed - $0) < 0.001 }) ?? 0
        case .sync:
            return 0
        case .info, .cast:
            return 0
        }
    }

    private func handleExit() {
        // Back out of a Subtitles sub-screen to the track list first; only then
        // does Menu close the whole panel.
        if openPanel == .subtitles && subtitleScreen != .tracks {
            openSubtitleScreen(subtitleScreen.parent)
            return
        }
        // Exactly the same rule one level down in the Cast tab, which it was
        // missing: Menu backs out of a person's details to the row of faces
        // first, and only closes the card once you are already on the row.
        // Without this, one press from a person's credits dismissed the whole
        // pane and the only way back to the row was the on-screen button.
        if openPanel == .cast, castDetailPerson != nil {
            // Hand it to the panel rather than clearing the state here: the
            // close is an animation plus a focus handover, and doing it from
            // outside skipped both — the pane vanished instead of shrinking, and
            // the row was left with every face but one disabled, which is why Up
            // from the tab stopped reaching the scrub bar.
            castCloseRequest &+= 1
            return
        }
        if openPanel == .info {
            // The card leaves with its tab, straight back to the scrub bar.
            closeInfoCard()
        } else if openPanel != nil {
            openPanel = nil   // onChange(of: openPanel) restores the transport focus
        } else {
            onExitToSurface()
        }
    }

    // MARK: Formatting

    static let speedPresets: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

    // Custom-speed grid for the − / + stepper: 0.25×…2.0× in 0.05 steps. Modelled
    // as integer indices so the stepper matches exactly (no Double == fuzziness);
    // the Double rate is derived on the way in (nearest index) and out (grid value).
    static let speedStepMin = 0.25
    static let speedStepMax = 2.0
    static let speedStep = 0.05
    static var speedGridCount: Int {
        Int(((speedStepMax - speedStepMin) / speedStep).rounded()) + 1
    }
    static func speedGridValue(_ index: Int) -> Double {
        ((speedStepMin + Double(index) * speedStep) * 100).rounded() / 100
    }
    static func nearestSpeedIndex(_ speed: Double) -> Int {
        let raw = ((speed - speedStepMin) / speedStep).rounded()
        return Int(min(max(raw, 0), Double(speedGridCount - 1)))
    }

    static func speedLabel(_ speed: Double) -> String {
        if abs(speed - speed.rounded()) < 0.001 {
            return String(format: "%.0f×", speed)
        }
        return String(format: "%.2f×", speed).replacingOccurrences(of: "0×", with: "×")
    }

    static func delayLabel(_ seconds: TimeInterval) -> String {
        // Seconds with two decimals: matches the 50 ms step (0.05 increments) and
        // reads cleaner at TV distance than a 4-digit millisecond value.
        let rounded = (seconds * 100).rounded() / 100
        if rounded == 0 { return "0.00s" }
        return String(format: rounded > 0 ? "+%.2fs" : "%.2fs", rounded)
    }

    /// Human explanation of the current subtitle delay, shown under the sync
    /// stepper. At 0 it teaches which chip does what; once adjusted it states the
    /// actual result (positive delay = subtitles show later than the audio),
    /// which resolves the perennial "does + make them earlier or later?" confusion.
    static func subtitleSyncHint(_ seconds: TimeInterval) -> LocalizedStringResource {
        let rounded = (seconds * 100).rounded() / 100
        if rounded == 0 {
            return "− shows subtitles earlier\n+ shows them later"
        }
        let magnitude = String(format: "%.2f", abs(rounded))
        return rounded > 0
            ? "Subtitles show \(magnitude)s later than the audio"
            : "Subtitles show \(magnitude)s earlier than the audio"
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Exact rendered width of an under-bar time label, measured synchronously
    /// with UIKit using the matching monospaced-digit font. We measure here (not
    /// via SwiftUI `PreferenceKey`s) because the `.background`/preference trick
    /// does not propagate through `.hidden()` on tvOS — verified on-device, the
    /// preference never fired so the labels never clamped or faded.
    static func measuredTimeWidth(_ string: String) -> CGFloat {
        let pointSize = UIFont.preferredFont(forTextStyle: .callout).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        let bounds = (string as NSString).size(withAttributes: [.font: font])
        return ceil(bounds.width)
    }

    /// Shared asymmetric fade for the transport chrome that hides while scrubbing
    /// (title block, button row, and the under-bar status glyph): it vanishes
    /// instantly when a scrub *starts* (quick ease) but waits before fading back
    /// in once it *stops* (delayed ease), so all those elements return together
    /// and rapid multi-scrubs never flash them back between swipes. Evaluated
    /// against the NEW `isScrubbing` value, so the start→hide and stop→show
    /// transitions each pick the matching curve.
    static func transportFadeAnimation(scrubbing: Bool) -> Animation {
        scrubbing
            ? .easeOut(duration: 0.1)
            : .easeOut(duration: 0.2).delay(0.45)
    }
}

extension PlayerControlsModel {
    /// The track controls the current engine/source can actually offer, in the
    /// order the track row lays them out: Speed · Audio · **Subtitles** (Subtitles
    /// nearest the trailing edge, where its panel opens from).
    ///
    /// Lives on the model rather than the view so `CustomPlayerContainer` can ask
    /// the same question before dropping focus into the row on an Up press — an
    /// empty row must flash the transport instead of swallowing the press.
    ///
    /// A/V Sync is intentionally omitted for now — the standalone button was
    /// removed. `Category.sync` + `syncPane` are kept so it can be restored later.
    var trackControlCategories: [PlayerControls.Category] {
        var result: [PlayerControls.Category] = []
        if engineCapabilities.contains(.playbackSpeed) {
            result.append(.speed)
        }
        if !audioOptions.isEmpty || engineCapabilities.contains(.dialogEnhance) {
            result.append(.audio)
        }
        if hasSelectableSubtitles {
            result.append(.subtitles)
        }
        return result
    }
}

#endif
