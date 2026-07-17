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

/// The complete custom-player transport: a title bar, the scrub bar (with
/// buffered/played fill + floating trickplay thumbnail), and — directly beneath
/// the scrubber — a **focusable row of native tvOS buttons** (Audio & Subtitles ·
/// Speed · A/V Sync · Diagnostics), modelled on Netflix / the Apple
/// TV app.
///
///  * The button row is **visible whenever the transport is** so viewers can see
///    what's available; focus only drops into it on swipe-down / Down, and
///    returns to the scrub surface on Up / Menu.
///  * Selecting a category expands its options as a panel that floats just above
///    the scrubber, so the row stays put.
///  * Playback keeps running while adjusting (Infuse-style) so track/speed/sync
///    changes have instant feedback.
///  * Capability-driven — rows the active engine can't honour are hidden.
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
        case subtitles, audio, speed, sync, info

        var title: String {
            switch self {
            case .subtitles: return "Subtitles"
            case .audio: return "Audio"
            case .speed: return "Speed"
            case .sync: return "A/V Sync"
            case .info: return "Info"
            }
        }

        var icon: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .audio: return "waveform"
            case .speed: return "speedometer"
            case .sync: return "slider.horizontal.below.square.and.square.filled"
            case .info: return "info.circle"
            }
        }
    }

    private enum FocusSlot: Hashable {
        case button(Category)
        case infoNext       // Info panel: Next Episode
        case infoPrev       // Info panel: Previous Episode
        case infoRestart    // Info panel: Restart
        case infoStats      // Info panel: Playback Info (diagnostics) toggle
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
    private enum SubtitleScreen: Equatable {
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

    @State private var openPanel: Category?
    @State private var subtitleScreen: SubtitleScreen = .tracks
    @FocusState private var focus: FocusSlot?

    /// Named coordinate space spanning the whole bottom cluster (panel slot +
    /// scrubber + button row) so the Speed button's leading edge can be measured
    /// in the same frame the Speed panel is laid out in.
    private static let bottomClusterSpace = "PlayerBottomCluster"

    /// Measured leading-edge X of the Speed button, in `bottomClusterSpace`. The
    /// Speed panel left-aligns to this so it opens directly under its own button.
    @State private var speedButtonLeading: CGFloat = 0

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

    /// Hold-to-accelerate state for the numeric style rows. `.onMoveCommand`
    /// repeats while a direction is held on the remote, so we ramp the step size
    /// as a same-direction streak builds on one focused row (fine taps stay 1×;
    /// a sustained hold climbs 1→2→4→8 grid steps). Any pause beyond the hold
    /// window, a direction flip, or a row change restarts at the fine step. The
    /// ramp state machine lives in `SubtitleStyleAccelerator`.
    @State private var styleAccelerator = SubtitleStyleAccelerator()

    var body: some View {
        ZStack {
            dimScrim
            VStack(spacing: 0) {
                if !styleEditing { Spacer(minLength: 0) }
                bottomCluster
                    .opacity(model.controlsVisible ? 1 : 0)
                // When the appearance editor is open the whole cluster flips to
                // top-anchored so the panel pins to the top-right corner (top
                // margin == side margin) instead of growing up from the transport.
                if styleEditing { Spacer(minLength: 0) }
            }
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
            .animation(.easeInOut(duration: 0.3), value: styleEditing)
        }
        .ignoresSafeArea()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ControlsHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ControlsHeightKey.self) { availableHeight = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipHintVisible)
        .onChange(of: model.controlBarVisible) { _, focused in
            openPanel = nil
            titleVisible = true
            // Don't force a specific button when the bar takes focus — imperatively
            // setting @FocusState here fought the engine's own default pick and
            // briefly lit two buttons at once. Let the engine choose on entry; only
            // clear our binding when focus leaves the bar.
            if !focused { focus = nil }
        }
        .onChange(of: openPanel) { _, panel in
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
            titleVisible = false
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
        .onChange(of: model.subtitleDownloadState) { _, state in
            // When search results land (async) while the Download screen is open,
            // move focus onto the first result so it's immediately actionable —
            // instead of leaving it parked on Back. Deferred for the same reason as
            // panel-open focus: let tvOS's own pass run first, then land ours.
            guard openPanel == .subtitles, subtitleScreen == .download else { return }
            if case .results = state { restoreFocus(.row(0)) }
        }
        .onExitCommand { handleExit() }
        .onPlayPauseCommand { actions.togglePlayPause() }
        .onMoveCommand { direction in
            if direction == .up && openPanel == nil { onExitToSurface() }
        }
    }

    // MARK: Bottom cluster (title + scrubber + buttons)

    private var bottomCluster: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The context slot directly above the scrub bar: normally the now-playing
            // title/description; when a panel opens it cross-fades to the panel (the
            // title/description are repetitive with the Info card, so they fade out).
            ZStack(alignment: .bottomLeading) {
                titleBlock
                    .opacity(titleVisible ? 1 : 0)
                if let openPanel {
                    panelContainer(for: openPanel)
                        .focusSection()
                        // Grow + fade from the corner nearest the button that opened
                        // it so it reads as springing from the control rather than
                        // zooming out of screen-centre. Panels that pin to the trailing
                        // edge (Audio/Subtitles/Sync) grow from `.bottomTrailing`; Info
                        // and Speed align to the LEFT of their own button, so they grow
                        // from `.bottomLeading`. Anchoring Speed to `.bottomTrailing`
                        // put the origin at the box's far (right) edge, away from its
                        // button — reading as a zoom from centre.
                        .transition(
                            .scale(
                                scale: 0.9,
                                anchor: (openPanel == .info || openPanel == .speed)
                                    ? .bottomLeading : .bottomTrailing
                            )
                            .combined(with: .opacity)
                        )
                }
            }
            // Transport block (scrubber + buttons). Hidden entirely while the
            // full-height appearance editor is open so the live subtitles behind
            // it are unobstructed; measured otherwise so other panels can size to
            // match. Its removal/return animates with the panel's height change.
            if !styleEditing {
                VStack(alignment: .leading, spacing: 18) {
                    scrubberRow
                    buttonRow
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TransportHeightKey.self, value: proxy.size.height)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onPreferenceChange(TransportHeightKey.self) { transportHeight = $0 }
        .coordinateSpace(name: Self.bottomClusterSpace)
        .onPreferenceChange(SpeedButtonLeadingKey.self) { speedButtonLeading = $0 }
        .animation(.easeInOut(duration: 0.2), value: openPanel)
        .animation(.easeInOut(duration: 0.28), value: titleVisible)
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        .animation(Self.transportFadeAnimation(scrubbing: model.isScrubbing), value: model.isScrubbing)
        .padding(.horizontal, 60)
        // Even margins in editor mode (60 all round); otherwise the usual top-heavy
        // transport layout. The top shrinks so the full-height panel clears overscan.
        .padding(.top, styleEditing ? 60 : 90)
        .padding(.bottom, styleEditing ? 60 : 48)
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
                && (model.skipHintVisible || (model.isPaused && model.intendsPause) || model.isSeeking)
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
        if model.skipHintVisible {
            Image(systemName: model.skipHintForward
                ? model.skipForwardInterval.forwardSymbol
                : model.skipBackwardInterval.backwardSymbol)
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

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 20) {
            // Utility cluster (far left): media Info. (The Diagnostics/Stats
            // toggle moved into the Info card so the transport row stays lean.)
            Button {
                toggle(.info)
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: openPanel == .info)
            .focused($focus, equals: .button(.info))

            Spacer(minLength: 20)

            // Track controls (far right), grouped: Speed · Audio · Subtitles.
            ForEach(availableCategories, id: \.self) { category in
                Button {
                    toggle(category)
                } label: {
                    Label(category.title, systemImage: category.icon)
                        .labelStyle(.iconOnly)
                }
                .playerGlassButton(prominent: openPanel == category)
                .focused($focus, equals: .button(category))
                .background {
                    // Publish the Speed button's leading edge so its panel can
                    // open left-aligned to the button rather than the far edge.
                    if category == .speed {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SpeedButtonLeadingKey.self,
                                value: proxy.frame(in: .named(Self.bottomClusterSpace)).minX
                            )
                        }
                    }
                }
            }
        }
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .allowsHitTesting(!model.isScrubbing)
        // Trap focus inside an open panel: while one is up, the transport buttons
        // drop out of the focus engine so directional nav can't wander out of the
        // menu. It closes only by selecting a row or pressing Menu (native-menu
        // behaviour). The scrub surface is already non-focusable while the bar owns
        // focus, so the open panel becomes the sole focusable region.
        .disabled(openPanel != nil)
    }

    private func toggle(_ category: Category) {
        if openPanel == category {
            openPanel = nil   // focus restoration handled centrally in onChange(of: openPanel)
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
    /// row for the track lists, the first available delay row for Sync, the primary
    /// action for Info, and the right control for each Subtitles sub-screen. Deferred
    /// onto `focus` in `onChange(of: openPanel)` via `restoreFocus`.
    private var preferredPanelFocus: FocusSlot? {
        guard let panel = openPanel else { return nil }
        switch panel {
        case .info:
            return model.hasNextEpisode ? .infoNext
                : (model.hasPreviousEpisode ? .infoPrev : .infoRestart)
        case .subtitles:
            switch subtitleScreen {
            case .tracks:
                return .row(selectedRowIndex(for: .subtitles))
            case .download:
                // Land on the first result when we have them; while still searching
                // (no rows yet) rest on Back. An async results arrival is handled by
                // an onChange that moves focus onto the first row.
                if case .results = model.subtitleDownloadState { return .row(0) }
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

    @ViewBuilder
    private func panelContainer(for category: Category) -> some View {
        if category == .info {
            infoPanel
                .colorScheme(.dark)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            morphingPanel(for: category)
        }
    }

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
    @ViewBuilder
    private func morphingPanel(for category: Category) -> some View {
        let styleFamily = category == .subtitles && subtitleScreen.isStyleFamily
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(for: category)
            Divider().background(.white.opacity(0.15))
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
        // Speed opens left-aligned under its own button; the other panels pin
        // to the trailing edge above the track-button cluster.
        .modifier(PanelHorizontalPlacement(
            leadingInset: category == .speed ? speedButtonLeading : nil
        ))
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
        case .audio: audioPane
        case .speed: speedPane
        case .sync: syncPane
        case .info: EmptyView()
        }
    }

    /// True while the ✎ Edit appearance editor (or one of its detail sub-screens)
    /// is open. In this mode we hide the transport chrome and dim gradient and pin
    /// the content-sized panel to the top-right corner, so the live subtitles
    /// behind and beside it are unobstructed and every tweak is easy to see.
    private var styleEditing: Bool {
        openPanel == .subtitles && subtitleScreen.isStyleFamily
    }

    // MARK: Info panel

    /// The bottom metadata row content: "S2 · E7 · 42m" (season/episode + runtime),
    /// shown inline with the technical badges — Apple-TV style.
    private var infoMetaLine: String {
        [model.infoEpisodeTag, model.infoRuntimeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A wide now-playing card that fades in over the title/description slot (the
    /// video keeps playing full-frame behind it). A fixed-height 16:9 thumbnail
    /// drives the card height so the art fills top-to-bottom and the borders stay
    /// equidistant on every edge whether or not the item has a description. The
    /// headline is the episode (not the show) title; season/episode + runtime ride
    /// inline with the badges on the bottom row.
    ///
    /// The right column holds an **icon-only** action row (Restart · Previous ·
    /// Next Episode) pinned to the top and a subtle **Playback Info** toggle pinned
    /// to the bottom (it drives the diagnostics overlay, moved off the transport
    /// row). The focused action expands to show its label — the tvOS equivalent of
    /// a tooltip, since there is no hover. Icons keep the row short so the artwork —
    /// not a tall stack of text buttons — governs the card height (no dead space
    /// beneath it).
    private var infoPanel: some View {
        // Concentric radii, matching the app's cards: the thumbnail's media radius
        // nested inside the card's glass radius (outer = inner + content padding),
        // so both corners share a centre.
        let thumbRadius = PlozzTheme.Metrics.mediumMediaCornerRadius
        let contentPad: CGFloat = 24
        let thumbHeight: CGFloat = 210

        return HStack(alignment: .top, spacing: 28) {
            infoThumbnail(cornerRadius: thumbRadius, height: thumbHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.infoHeadline.isEmpty ? "Now Playing" : model.infoHeadline)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !model.overview.isEmpty {
                    // Ellipsis, no `fixedSize`: the overview truncates instead of
                    // forcing its full height, so a long synopsis can never push
                    // the meta/badge row off the bottom of the card (it stays
                    // pinned by the Spacer below).
                    Text(model.overview)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .padding(.top, 1)
                }
                Spacer(minLength: 8)
                // Bottom metadata row: season/episode + runtime, then the technical
                // badges, all on one baseline pinned to the card's bottom edge.
                HStack(alignment: .center, spacing: 12) {
                    if !infoMetaLine.isEmpty {
                        Text(infoMetaLine)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if !model.infoBadges.isEmpty {
                        MediaBadgeRow(badges: model.infoBadges)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(height: thumbHeight, alignment: .topLeading)

            Spacer(minLength: 32)

            // Right column: icon action row pinned top, Playback Info toggle
            // pinned bottom. Both are full-width focus sections so a Down press
            // from ANY top button (even the left-most Restart) routes to Playback
            // Info: a right-aligned single button wouldn't sit under Restart, so
            // the bottom row spans the column width (Spacer + button) and is its
            // own `.focusSection()`, bridging the horizontal offset.
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    // Order: Restart · Previous · Next Episode (primary, far right).
                    infoActionButton(title: "Restart", icon: "arrow.counterclockwise", prominent: false, slot: .infoRestart) {
                        actions.restart()
                        openPanel = nil   // focus restored centrally in onChange(of: openPanel)
                    }
                    if model.hasPreviousEpisode {
                        infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                            actions.playPreviousEpisode()
                        }
                    }
                    if model.hasNextEpisode {
                        infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                            actions.playNextEpisode()
                        }
                    }
                }
                .focusSection()
                Spacer(minLength: 0)
                // Subtle Playback Info (diagnostics) toggle, bottom-right —
                // balances the tech badges bottom-left. Keeps the Info panel open
                // so the viewer can flip it and watch the top-left overlay appear.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    infoActionButton(
                        title: "Playback Info",
                        icon: "cpu",
                        prominent: model.diagnosticsEnabled,
                        slot: .infoStats
                    ) {
                        model.diagnosticsEnabled.toggle()
                    }
                }
                .focusSection()
            }
            .frame(height: thumbHeight, alignment: .topTrailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(contentPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
    }

    private func infoThumbnail(cornerRadius: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: height * 16.0 / 9.0, height: height)
            .overlay {
                FallbackAsyncImage(urls: model.artworkURLs, variant: .landscapeCard) {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(.white.opacity(0.28))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .plozzMediaEdge(cornerRadius: cornerRadius)
    }

    /// An icon-only Info-card action. At rest it shows just its glyph; while
    /// focused it **expands** to reveal its label (the tvOS stand-in for a hover
    /// tooltip). The width/expand animates, but the focus **colours are instant**:
    /// the `.animation` is scoped to the label's layout only, so the capsule grows
    /// smoothly while `InfoActionButtonStyle` swaps fill/foreground on the same
    /// frame (the stock glass styles animate their focus tint, which can't be
    /// disabled from outside — hence the custom style).
    private func infoActionButton(
        title: String,
        icon: String,
        prominent: Bool,
        slot: FocusSlot,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == slot
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                if isFocused {
                    // `.identity` (no fade): the label appears at full opacity and
                    // is revealed by the capsule growing around it, so the reveal
                    // reads as pure movement, not a cross-fade.
                    Text(title).fixedSize().transition(.identity)
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            // Scope the animation to the label's layout: the capsule (sized to the
            // label in the style) follows this and grows smoothly, while the fill
            // and text colours — applied OUTSIDE this scope — change instantly.
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(InfoActionButtonStyle(focused: isFocused, prominent: prominent))
        .focused($focus, equals: slot)
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
                .buttonStyle(PanelHeaderButtonStyle())
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
                    .buttonStyle(PanelHeaderButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .subSync)
                }
                Button {
                    openSubtitleScreen(.style)
                } label: {
                    Label("Style", systemImage: "paintpalette")
                }
                .buttonStyle(PanelHeaderButtonStyle())
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
        .focusSection()
    }

    private func headerTitle(for category: Category) -> String {
        guard category == .subtitles else { return category.title }
        switch subtitleScreen {
        case .tracks: return "Subtitles"
        case .download: return "Download Subtitles"
        case .sync: return "Subtitle Sync"
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
            subtitleDownloadStub
                .frame(minHeight: Self.panelBodyMaxHeight, alignment: .top)
        case .sync: subtitleSyncScreen
        case .style:
            // A bitmap primary (PGS/DVD/…) is pre-rendered by the source, so NONE
            // of the appearance controls apply. Replace the whole editor with a
            // centered explanation rather than showing dead knobs.
            if let format = model.secondarySubtitleImagePrimaryFormat {
                styleUnavailableForImageSubtitle(format: format)
            } else {
                let main = styleMainRows
                styleScreen(main.rows, dividerBefore: main.dividerBefore)
            }
        case .styleFont: styleFontScreen
        case .styleOutline: styleScreen(styleOutlineRows)
        case .styleBackground: styleScreen(styleBackgroundRows)
        case .styleDual: styleScreen(styleDualRows)
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
                trackRowStack(rows)
            }
            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            if model.canSearchRemoteSubtitles {
                downloadEntryRow
            }
            #if DEBUG
            if !model.primarySubtitleDiagnostic.isEmpty {
                Text(model.primarySubtitleDiagnostic)
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
            if case .results = model.subtitleDownloadState {} else {
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

    // MARK: Subtitles sub-screens (Download search / live Style editor)

    /// The in-player subtitle **search + download** screen. Shows a spinner while
    /// searching, the ranked results (with Forced/SDH badges) to pick from, or a
    /// friendly empty/error state. Picking a result downloads it server-side and
    /// hot-loads it into the running player.
    @ViewBuilder
    private var subtitleDownloadStub: some View {
        switch model.subtitleDownloadState {
        case .idle, .searching:
            subtitleDownloadStatus(
                systemImage: "magnifyingglass",
                title: "Searching for subtitles…",
                detail: "Looking through your server's subtitle source.",
                showSpinner: true
            )
        case .results(let subs):
            subtitleResultsList(subs)
        case .empty:
            subtitleDownloadStatus(
                systemImage: "text.magnifyingglass",
                title: "No subtitles found",
                detail: "Nothing matched in your language. If this is a Plex or Jellyfin server, make sure a subtitle source (e.g. OpenSubtitles) is set up on the server."
            )
        case .downloading:
            subtitleDownloadStatus(
                systemImage: "arrow.down.circle",
                title: "Downloading subtitle…",
                detail: "Fetching it and loading it into the player.",
                showSpinner: true
            )
        case .added:
            subtitleDownloadStatus(
                systemImage: "checkmark.circle.fill",
                title: "Subtitle added",
                detail: "It's now playing and available in your subtitle list."
            )
        case .failed:
            subtitleDownloadStatus(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't get that subtitle",
                detail: "Something went wrong searching or downloading. Try again."
            )
        }
    }

    private func subtitleDownloadStatus(systemImage: String, title: String, detail: String, showSpinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView()
                } else {
                    Image(systemName: systemImage).font(.title3)
                }
                Text(title).font(.callout.weight(.semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        // Fill the pinned Download-screen height and centre, so the spinner /
        // message sits in the middle of the box rather than jammed top-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func subtitleResultsList(_ subs: [RemoteSubtitle]) -> some View {
        // A plain column (NOT a ScrollView): the enclosing `morphingBody` already
        // provides the scroll + height measurement that drives the open/height
        // morph, exactly like the track list. A nested ScrollView here is greedy
        // vertically, breaks that measurement (so the panel wouldn't animate open),
        // and reads as janky.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(subs.prefix(30).enumerated()), id: \.element.id) { index, sub in
                Button {
                    actions.downloadRemoteSubtitle(sub)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: Self.remoteSubtitleTitle(sub), font: .body)
                        Text(Self.remoteSubtitleDetail(sub))
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerMenuRowButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .row(index))
            }
        }
        .padding(.horizontal, 14)
    }

    /// The candidate's display name, falling back to language when unnamed.
    private static func remoteSubtitleTitle(_ sub: RemoteSubtitle) -> String {
        if !sub.name.isEmpty { return sub.name }
        if let language = sub.language { return SubtitleLanguageCatalog.displayName(forCode: language) ?? language }
        return "Subtitle"
    }

    /// The language · downloads · badges line beneath a candidate. The provider is
    /// omitted for OpenSubtitles (Plex's only source, and Jellyfin's usual one — so
    /// it's noise); a *different* provider is shown since then it's informative.
    private static func remoteSubtitleDetail(_ sub: RemoteSubtitle) -> String {
        var parts: [String] = []
        if let provider = sub.providerName, !provider.isEmpty,
           !provider.lowercased().replacingOccurrences(of: " ", with: "").contains("opensubtitles") {
            parts.append(provider)
        }
        if let language = sub.language,
           let name = SubtitleLanguageCatalog.displayName(forCode: language) { parts.append(name) }
        if let count = sub.downloadCount, count > 0 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            parts.append("\(formatted) downloads")
        }
        if sub.isForced { parts.append("Forced") }
        if sub.isHearingImpaired { parts.append("SDH") }
        return parts.isEmpty ? "Tap to download" : parts.joined(separator: " · ")
    }

    /// Compact timing screen reached from the header Sync chip: nudge the primary
    /// subtitle earlier/later to line it up with the audio. A single − / value / +
    /// stepper in 50 ms steps (matching the Speed stepper's look), with a dynamic
    /// hint that states the current earlier/later result. Only offered when the
    /// app's overlay owns the active subtitle, so the chip that opens it is gated
    /// the same way.
    private var subtitleSyncScreen: some View {
        VStack(spacing: 20) {
            delayStepper(
                value: model.subtitleDelaySeconds,
                minusSlot: 0,
                plusSlot: 1,
                step: 0.05,
                onAdjust: { actions.setSubtitleDelay(model.subtitleDelaySeconds + $0) }
            )
            Text(Self.subtitleSyncHint(model.subtitleDelaySeconds))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.15), value: model.subtitleDelaySeconds)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    /// A compact − / value / + stepper for the subtitle-sync screen. The ± are
    /// discrete focusable chips (bound to `minusSlot` / `plusSlot`) that reuse the
    /// Speed stepper's circular `StepperButtonStyle`; the live value sits centred
    /// between them in ms.
    private func delayStepper(
        value: TimeInterval,
        minusSlot: Int,
        plusSlot: Int,
        step: TimeInterval,
        onAdjust: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack(spacing: 24) {
            Button { onAdjust(-step) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(StepperButtonStyle())
            .focused($focus, equals: .row(minusSlot))

            Text(Self.delayLabel(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.16), value: value)
                .frame(minWidth: 104)

            Button { onAdjust(step) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(StepperButtonStyle())
            .focused($focus, equals: .row(plusSlot))
        }
        .padding(.vertical, 4)
    }

    // MARK: Subtitle style editor (hybrid full-width rows)

    /// One appearance control, rebuilt every render so its value string and its
    /// mutation closures always read/write the freshest `SubtitleStyle`. `slot` is
    /// the per-screen focus index (`.row(slot)`); screens never coexist so slots
    /// restart at 0 on each screen with no collision.
    private struct StyleRowSpec: Identifiable {
        enum Kind {
            /// Numeric range: ←/→ step (hold to accelerate), Select nudges up one.
            /// `step` moves by a signed number of grid indices, clamped at the ends.
            case number(value: String, step: (Int) -> Void)
            /// Small enum: Select cycles next (wrap); ←/→ cycle; no ± glyphs.
            case choice(value: String, prev: () -> Void, next: () -> Void)
            /// On/off: Select flips.
            case toggle(isOn: Bool, flip: () -> Void)
            /// Opens a detail sub-screen: Select opens; shows a `›` chevron.
            case submenu(summary: String, open: () -> Void)
            /// One-shot: Select runs it.
            case action(run: () -> Void)
        }
        let slot: Int
        let title: String
        let kind: Kind
        var id: Int { slot }
    }

    /// The live subtitle-appearance editor, hosted over the running video so every
    /// tweak previews instantly on the real subtitles behind the panel. Each row is
    /// a single full-width Button (one focus target spanning the width, so vertical
    /// focus lands predictably), value right-aligned. Steppers reveal −/+ glyphs
    /// only while focused (press ←/→ on the remote to adjust); the container's
    /// `.onMoveCommand` — attached to the non-focusable VStack so children keep
    /// native up/down nav — dispatches those left/right steps to the focused row.
    /// Edits funnel through `updateStyle` → `actions.setSubtitleStyle` (live overlay
    /// + profile persistence). Back lives in the panel header.
    @ViewBuilder
    private func styleScreen(_ rows: [StyleRowSpec], dividerBefore: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if let d = dividerBefore, row.slot == d {
                    Divider()
                        .background(.white.opacity(0.12))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                styleRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .onMoveCommand { direction in handleStyleMove(direction, rows: rows) }
    }

    /// One rendered row, laid out to match the track/audio rows exactly: a full-width
    /// Button with the title hard-left and the value/glyph hard-right, so titles and
    /// values carry equal edge gutters. Steppers reveal −/+ flanking the value on
    /// focus; submenus show a trailing chevron.
    @ViewBuilder
    private func styleRow(_ row: StyleRowSpec) -> some View {
        let isFocused = focus == .row(row.slot)
        Button {
            switch row.kind {
            case let .number(_, step): step(1)
            case let .choice(_, _, next): next()
            case let .toggle(_, flip): flip()
            case let .submenu(_, open): open()
            case let .action(run): run()
            }
        } label: {
            // Mirror the track/audio rows exactly: title hard-left, a Spacer, and
            // the value/glyph hard-right against the same trailing padding the
            // checkmark uses. Title and trailing element therefore carry equal edge
            // gutters (no extra leading slot pushing the title in).
            HStack(spacing: 10) {
                Text(row.title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                styleRowTrailing(row, isFocused: isFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.slot))
    }

    @ViewBuilder
    private func styleRowTrailing(_ row: StyleRowSpec, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            // − appears on focus for steppers, immediately left of the value.
            if case .number = row.kind, isFocused {
                Image(systemName: "minus").font(.body.weight(.semibold))
            }

            styleRowValue(row)

            // + on focus for steppers, or a persistent chevron for submenus — both
            // sit at the trailing edge, exactly where the track rows put their
            // checkmark, so the value column hugs the right like every other menu.
            switch row.kind {
            case .number:
                if isFocused { Image(systemName: "plus").font(.body.weight(.semibold)) }
            case .submenu:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .playerMenuRowSecondary()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func styleRowValue(_ row: StyleRowSpec) -> some View {
        switch row.kind {
        case let .number(value, _):
            Text(value).font(.body).monospacedDigit().playerMenuRowSecondary()
        case let .choice(value, _, _):
            Text(value).font(.body).lineLimit(2).multilineTextAlignment(.trailing).playerMenuRowSecondary()
        case let .toggle(isOn, _):
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
        case let .submenu(summary, _):
            Text(summary).font(.body).playerMenuRowSecondary()
        case .action:
            EmptyView()
        }
    }

    /// Container-level ←/→ handler: looks up the focused slot's row and steps it.
    /// Up/down are left to the native focus engine (single column → left/right
    /// find no sibling, so focus stays put and this handler fires instead).
    private func handleStyleMove(_ direction: MoveCommandDirection, rows: [StyleRowSpec]) {
        guard case let .row(slot)? = focus,
              let row = rows.first(where: { $0.slot == slot }) else { return }
        switch (direction, row.kind) {
        case let (.left, .number(_, step)):
            step(-styleAccelerator.magnitude(slot: slot, sign: -1))
        case let (.right, .number(_, step)):
            step(styleAccelerator.magnitude(slot: slot, sign: 1))
        case let (.left, .choice(_, prev, _)):
            prev()
        case let (.right, .choice(_, _, next)):
            next()
        default:
            break
        }
    }

    // MARK: Per-screen row builders

    /// Main flat Style screen: the common per-glyph knobs, a divider, then the
    /// submenu groups (outline/border, background box, dual subtitles) and Reset.
    /// The submenus own the quick control as their first row *and* echo its current
    /// value as their summary, so there is exactly one entry per concern here.
    private var styleMainRows: (rows: [StyleRowSpec], dividerBefore: Int) {
        let s = model.subtitleStyle
        let weights = s.fontFamily.availableWeights
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(StyleRowSpec(slot: slot, title: "Font", kind: .submenu(summary: s.fontFamily.displayName, open: { openSubtitleScreen(.styleFont) }))); slot += 1
        rows.append(choiceRow(slot, "Weight", options: weights, current: s.fontWeight.snapped(to: weights), label: { $0.displayName }) { v in updateStyle { $0.fontWeight = v } }); slot += 1
        rows.append(numberRow(slot, "Text Size", options: Self.sizeOptions, current: Int((s.fontScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.fontScale = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Position", options: Self.positionOptions, current: Int((s.verticalPosition * 100).rounded()), label: PlayerControlsFormatting.positionLabel) { v in updateStyle { $0.verticalPosition = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Offset", options: Self.hOffsetOptions, current: Int((s.horizontalOffset * 100).rounded()), label: PlayerControlsFormatting.hOffsetLabel) { v in updateStyle { $0.horizontalOffset = Double(v) / 100 } }); slot += 1
        rows.append(colorRow(slot, "Text Color", options: Self.textColorOptions, current: s.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.textColor = c } }); slot += 1
        rows.append(numberRow(slot, "Opacity", options: Self.opacityOptions, current: Int((s.opacity * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.opacity = Double(v) / 100 } }); slot += 1
        // Only affects HDR frames, so it appears exclusively while HDR is live —
        // mirroring how the bitmap-primary gate hides controls that can't act.
        if model.subtitlesRenderHDR {
            rows.append(numberRow(slot, "HDR Brightness", options: Self.hdrBrightnessOptions, current: Int((s.hdrLuminanceScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.hdrLuminanceScale = Double(v) / 100 } }); slot += 1
        }

        // The submenu group + Reset sit under a divider, wherever the knobs above end.
        let dividerBefore = slot
        rows.append(StyleRowSpec(slot: slot, title: "Shadow & Outline", kind: .submenu(summary: PlayerControlsFormatting.edgeSummary(s), open: { openSubtitleScreen(.styleOutline) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Background", kind: .submenu(summary: s.background.isEnabled ? "On" : "Off", open: { openSubtitleScreen(.styleBackground) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Dual Subtitles", kind: .submenu(summary: hasSecondaryTrack ? "On" : "Off", open: { openSubtitleScreen(.styleDual) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Reset to Default", kind: .action(run: { updateStyle { $0 = .default } }))); slot += 1
        return (rows, dividerBefore)
    }

    /// The Font picker: one selectable row per family, each rendered **in its own
    /// typeface** (a touch larger than the value rows) so the list previews itself.
    /// Selecting a font applies it and returns to the Style screen; the chosen
    /// weight persists and is re-snapped to the new family's available weights by
    /// the renderer and the Weight row.
    @ViewBuilder
    private var styleFontScreen: some View {
        let current = model.subtitleStyle.fontFamily
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SubtitleFontFamily.allCases.enumerated()), id: \.offset) { idx, family in
                fontChoiceRow(family, index: idx, isSelected: family == current)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func fontChoiceRow(_ family: SubtitleFontFamily, index: Int, isSelected: Bool) -> some View {
        Button {
            updateStyle { $0.fontFamily = family }
            openSubtitleScreen(.style)
        } label: {
            HStack(spacing: 10) {
                Text(family.displayName)
                    .font(Self.fontPreviewFont(for: family))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: isSelected, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    /// A SwiftUI `Font` that renders a family's name in that family's own Regular
    /// face — bundled faces via their PostScript name, SF via the system font, and
    /// SF Rounded via the rounded system design.
    private static func fontPreviewFont(for family: SubtitleFontFamily) -> Font {
        // OpenDyslexic's wide, heavy letterforms already read large, so it gets a
        // smaller preview; every other family is bumped up for a bolder, more
        // legible list.
        let size: CGFloat = family == .openDyslexic ? 30 : 40
        if family.usesRoundedDesign { return .system(size: size, design: .rounded) }
        if let stem = family.postScriptStem { return .custom("\(stem)-Regular", size: size) }
        return .system(size: size)
    }

    /// Shadow (depth) + a single glyph Outline — two independent concerns that
    /// compose freely (e.g. a drop shadow *and* an outline at once). Rows for each
    /// group's colour/size reveal only when that group is active, so there are no
    /// dead controls and never two competing "outline" concepts.
    private var styleOutlineRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(choiceRow(slot, "Shadow", options: Self.shadowStyleOptions, current: s.edge.style, label: { $0.displayName }) { v in updateStyle { $0.edge.style = v } }); slot += 1
        if s.edge.style != .none {
            rows.append(colorRow(slot, "Shadow Color", options: Self.textColorOptions, current: s.edge.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.edge.color = c } }); slot += 1
            rows.append(numberRow(slot, "Shadow Thickness", options: Self.thicknessOptions, current: Int(s.edge.thickness.rounded()), label: { "\($0)" }) { v in updateStyle { $0.edge.thickness = Double(v) } }); slot += 1
        }

        rows.append(StyleRowSpec(slot: slot, title: "Outline", kind: .toggle(isOn: s.border.isEnabled, flip: { updateStyle { $0.border.isEnabled.toggle() } }))); slot += 1
        if s.border.isEnabled {
            rows.append(colorRow(slot, "Outline Color", options: Self.textColorOptions, current: s.border.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.border.color = c } }); slot += 1
            rows.append(numberRow(slot, "Outline Width", options: Self.thicknessOptions, current: Int(s.border.width.rounded()), label: { "\($0)" }) { v in updateStyle { $0.border.width = Double(v) } }); slot += 1
        }
        return rows
    }

    /// Background box: colour, its own opacity, corner radius and padding.
    private var styleBackgroundRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        var rows: [StyleRowSpec] = [
            StyleRowSpec(slot: 0, title: "Show Box", kind: .toggle(isOn: s.background.isEnabled, flip: { updateStyle { $0.background.isEnabled.toggle() } })),
        ]
        // The box's colour/opacity/shape only matter when it's shown; hide them
        // while it's off so focus never lands on a control with no visible effect
        // (matching the Outline and Dual screens' gating).
        guard s.background.isEnabled else { return rows }
        var slot = 1
        rows.append(colorRow(slot, "Color", options: Self.boxColorOptions, current: s.background.color, label: PlayerControlsFormatting.boxColorLabel) { c in updateStyle { $0.background.color = c } }); slot += 1
        rows.append(numberRow(slot, "Box Opacity", options: Self.boxOpacityOptions, current: Int((s.background.color.alpha * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.background.color.alpha = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Corner Radius", options: Self.cornerOptions, current: Int(s.background.cornerRadius.rounded()), label: PlayerControlsFormatting.cornerLabel) { v in updateStyle { $0.background.cornerRadius = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Padding", options: Self.paddingOptions, current: Int(s.background.horizontalPadding.rounded()), label: { "\($0)" }) { v in updateStyle { $0.background.horizontalPadding = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Vertical Padding", options: Self.paddingOptions, current: Int(s.background.verticalPadding.rounded()), label: { "\($0)" }) { v in updateStyle { $0.background.verticalPadding = Double(v) } }); slot += 1
        return rows
    }

    /// True when a real (non-"Off") second subtitle track is currently selected,
    /// so the main Style screen can label "Dual Subtitles" On/Off correctly.
    private var hasSecondaryTrack: Bool {
        guard let sel = model.secondarySubtitleOptions.first(where: { $0.isSelected }) else { return false }
        return sel.id != PlayerTrackOption.offID
    }

    /// Dual subtitles: pick a second track to show a second line, then (optionally)
    /// distinguish its look. The picker lists text tracks the overlay can draw
    /// (excluding the primary); its styling rows appear only once a track is on.
    private var styleDualRows: [StyleRowSpec] {
        let s = model.subtitleStyle
        let secOptions = model.secondarySubtitleOptions
        let count = secOptions.count
        let currentIdx = secOptions.firstIndex(where: { $0.isSelected }) ?? 0
        let step: (Int) -> Void = { delta in
            guard count > 0 else { return }
            let next = secOptions[((currentIdx + delta) % count + count) % count]
            actions.selectSecondarySubtitle(next.id)
        }
        let selected = secOptions.first(where: { $0.isSelected })
        let hasTrack = selected != nil && selected?.id != PlayerTrackOption.offID
        // Base value = the selected option's label; when a real track is selected,
        // annotate it with the live load status so the viewer can see whether it's
        // fetching, has no lines in this file, or the sidecar was unavailable —
        // instead of a silent blank second line. When the primary is a bitmap sub,
        // dual mode is disallowed (a PGS/DVD line can't be positioned), so say so
        // explicitly rather than the ambiguous "None available".
        let baseValue: String
        if let format = model.secondarySubtitleImagePrimaryFormat {
            baseValue = "Disabled for \(format)"
        } else if secOptions.isEmpty {
            baseValue = "None available"
        } else {
            baseValue = secOptions[currentIdx].title
        }
        let trackValue = hasTrack ? baseValue + Self.secondaryStatusSuffix(model.secondarySubtitleStatus) : baseValue
        var rows: [StyleRowSpec] = [
            StyleRowSpec(slot: 0, title: "Second Track", kind: .choice(
                value: trackValue,
                prev: { step(-1) },
                next: { step(1) }
            )),
        ]
        if hasTrack, let sec = s.secondary {
            var slot = 1
            rows.append(choiceRow(slot, "Placement", options: SubtitleStyle.Secondary.Placement.allCases, current: sec.placement, label: { $0 == .above ? "Above" : "Below" }) { v in updateStyle { $0.secondary?.placement = v } }); slot += 1
            rows.append(StyleRowSpec(slot: slot, title: "Distinct Style", kind: .toggle(isOn: sec.differentiate, flip: { updateStyle { $0.secondary?.differentiate.toggle() } }))); slot += 1
            // Size + Colour only take effect when the secondary uses a distinct
            // style — otherwise the renderer mirrors the primary's size/colour
            // (see SubtitleOverlayView). Hide them while Distinct Style is off so
            // they're not dead controls.
            if sec.differentiate {
                rows.append(numberRow(slot, "Size", options: Self.secondarySizeOptions, current: Int((sec.relativeScale * 100).rounded()), label: { "\($0)%" }) { v in updateStyle { $0.secondary?.relativeScale = Double(v) / 100 } }); slot += 1
                rows.append(colorRow(slot, "Color", options: Self.textColorOptions, current: sec.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.secondary?.textColor = c } }); slot += 1
            }
            rows.append(numberRow(slot, "Gap", options: Self.gapOptions, current: Int(sec.gap.rounded()), label: { "\($0)" }) { v in updateStyle { $0.secondary?.gap = Double(v) } }); slot += 1
        }
        return rows
    }

    /// A short suffix annotating the selected second track with its load state.
    /// Always shows the outcome (loading / cue count / no lines / unavailable) so a
    /// track that fetched cues but still won't draw is distinguishable on-screen
    /// from one that genuinely returned nothing.
    private static func secondaryStatusSuffix(_ status: SecondarySubtitleStatus) -> String {
        switch status {
        case .idle: return ""
        case .loading: return "  ·  loading…"
        case .loaded(let n): return n > 0 ? "  ·  \(n) cues" : "  ·  no lines"
        case .unavailable: return "  ·  unavailable"
        }
    }

    // MARK: Row constructors

    /// Numeric stepper row over an Int grid; snaps a legacy off-grid value to the
    /// nearest listed option so it still displays and steps cleanly. Steps by a
    /// signed number of grid indices and clamps at both ends (no wrap), so a fast
    /// hold-to-accelerate run parks at Bottom/Top instead of jumping across.
    private func numberRow(_ slot: Int, _ title: String, options: [Int], current: Int, label: @escaping (Int) -> String, apply: @escaping (Int) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = Self.nearestIndex(options, current)
        return StyleRowSpec(slot: slot, title: title, kind: .number(
            value: label(options[idx]),
            step: { delta in
                let target = min(max(idx + delta, 0), n - 1)
                if target != idx { apply(options[target]) }
            }
        ))
    }

    /// Cycle row over any small `Equatable` set; wraps at both ends.
    private func choiceRow<V: Equatable>(_ slot: Int, _ title: String, options: [V], current: V, label: @escaping (V) -> String, apply: @escaping (V) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(of: current) ?? 0
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: label(options[idx]),
            prev: { apply(options[(idx - 1 + n) % n]) },
            next: { apply(options[(idx + 1) % n]) }
        ))
    }

    /// Cycle row over a colour palette, matched by RGB so it recognises the current
    /// swatch regardless of its alpha, and preserves that alpha on change (so the
    /// separate opacity knobs stay independent of the colour choice).
    private func colorRow(_ slot: Int, _ title: String, options: [SubtitleColor], current: SubtitleColor, label: @escaping (SubtitleColor) -> String, apply: @escaping (SubtitleColor) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(where: { $0.red == current.red && $0.green == current.green && $0.blue == current.blue }) ?? 0
        func withAlpha(_ c: SubtitleColor) -> SubtitleColor { SubtitleColor(red: c.red, green: c.green, blue: c.blue, alpha: current.alpha) }
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: label(current),
            prev: { apply(withAlpha(options[(idx - 1 + n) % n])) },
            next: { apply(withAlpha(options[(idx + 1) % n])) }
        ))
    }

    /// Reads the mirror, applies the mutation, and routes the result through the
    /// live-apply + persist funnel. Single write path for every appearance control.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        var next = model.subtitleStyle
        mutate(&next)
        actions.setSubtitleStyle(next)
    }

    // MARK: Option grids

    // Precise, numeric option grids — no "low / high" buckets.
    private static let sizeOptions: [Int] = Array(stride(from: 60, through: 250, by: 5))
    private static let positionOptions: [Int] = Array(stride(from: 0, through: 90, by: 1))
    /// Horizontal nudge as a signed percentage of the max offset (±25% of width);
    /// 0 = centred. Lets subtitles dodge burned-in signage / letterbox furniture.
    private static let hOffsetOptions: [Int] = Array(stride(from: -100, through: 100, by: 5))
    private static let opacityOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    /// The box's own opacity floors lower than text opacity (down to 5%) so a
    /// near-invisible scrim is possible without dragging the text there too.
    private static let boxOpacityOptions: [Int] = Array(stride(from: 5, through: 100, by: 5))
    /// Subtitle HDR white-point scale, shown as a percentage. Mirrors the model's
    /// `hdrLuminanceScale` (0.2–1.0); only surfaced while HDR is live.
    private static let hdrBrightnessOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    private static let thicknessOptions: [Int] = Array(stride(from: 0, through: 10, by: 1))
    /// Shadow (depth) styles only — the outline is now its own toggle, so the old
    /// `.uniform` case is intentionally not offered here.
    private static let shadowStyleOptions: [SubtitleEdgeStyle] = [.none, .dropShadow, .raised, .depressed]
    /// Corner radius in points, then a large sentinel the box renderer clamps to a
    /// perfect capsule (`UIBezierPath` caps the radius at half the shorter side),
    /// so the top of the range always reads as "fully rounded" at any box size.
    private static let cornerFull = PlayerControlsFormatting.cornerFull
    private static let cornerOptions: [Int] = Array(stride(from: 0, through: 40, by: 2)) + [cornerFull]
    private static let paddingOptions: [Int] = Array(stride(from: 0, through: 40, by: 2))
    private static let gapOptions: [Int] = Array(stride(from: 0, through: 24, by: 2))
    private static let secondarySizeOptions: [Int] = Array(stride(from: 50, through: 100, by: 5))
    private static let textColorOptions: [SubtitleColor] = SubtitleColor.presets.map(\.color)
    // RGB representatives (alpha handled by the Box Opacity knob).
    private static let boxColorOptions: [SubtitleColor] = [
        SubtitleColor(red: 0, green: 0, blue: 0, alpha: 1),
        SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
        SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)
    ]

    private static func nearestIndex(_ options: [Int], _ value: Int) -> Int {
        PlayerControlsFormatting.nearestIndex(options, value)
    }

    /// Shown in place of the whole style editor when the primary subtitle is a
    /// bitmap (PGS/DVD/DVB/VobSub): those cues are pre-rendered images by the
    /// source, so none of the font/colour/size/position controls apply. A calm
    /// centered card explains why rather than presenting dead knobs.
    private func styleUnavailableForImageSubtitle(format: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "photo")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(format) subtitles can't be restyled")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("They're rendered as images by the source, so font, colour, size and position controls don't apply.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
    @ViewBuilder
    private var audioPane: some View {
        let rows = audioRows
        if rows.isEmpty {
            emptyRow("No alternate audio")
        } else {
            trackRowStack(rows).padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func trackRowStack(_ rows: [TrackRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if row.isToggle {
                    compactToggleRow(row)
                } else {
                    compactSelectableRow(row)
                }
            }
        }
    }

    private func compactSelectableRow(_ row: TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                if row.isExternal {
                    // Marks a subtitle that isn't embedded in the video — one you
                    // downloaded this session, or a local sidecar file — so it's
                    // findable in a list full of same-language embedded tracks.
                    ExternalSubtitleBadge()
                }
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }

    private func compactToggleRow(_ row: TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.body.weight(.medium)).lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: row.isSelected, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }

    @ViewBuilder
    private var speedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fine control: − {value}× + in 0.05 steps (0.25×–2×). Drives the same
            // model.playbackSpeed as the presets below, so they stay in sync.
            HStack {
                Spacer(minLength: 0)
                SettingsStepper(
                    options: Array(0..<Self.speedGridCount),
                    selection: Binding(
                        get: { Self.nearestSpeedIndex(model.playbackSpeed) },
                        set: { actions.setPlaybackSpeed(Self.speedGridValue($0)) }
                    ),
                    compact: true,
                    title: { Self.speedLabel(Self.speedGridValue($0)) }
                )
                Spacer(minLength: 0)
            }
            // The enclosing ScrollView already adds 10pt above this pane, so give
            // the stepper less top / more bottom padding to visually center it
            // between the panel header and the presets divider (≈14pt each side).
            .padding(.top, 4)
            .padding(.bottom, 14)

            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            // Quick presets.
            ForEach(Array(Self.speedPresets.enumerated()), id: \.offset) { index, speed in
                selectableRow(
                    title: Self.speedLabel(speed),
                    isSelected: abs(model.playbackSpeed - speed) < 0.001,
                    index: index
                ) {
                    actions.setPlaybackSpeed(speed)
                }
            }
        }
    }

    @ViewBuilder
    private var syncPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.engineCapabilities.contains(.audioDelay) {
                delayRow(
                    title: "Audio Delay",
                    value: model.audioDelaySeconds,
                    firstSlot: 0,
                    onAdjust: { actions.setAudioDelay(model.audioDelaySeconds + $0) },
                    onReset: { actions.setAudioDelay(0) }
                )
            }
            if model.engineCapabilities.contains(.subtitleDelay) {
                delayRow(
                    title: "Subtitle Delay",
                    value: model.subtitleDelaySeconds,
                    firstSlot: 10,
                    onAdjust: { actions.setSubtitleDelay(model.subtitleDelaySeconds + $0) },
                    onReset: { actions.setSubtitleDelay(0) }
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: Rows

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
    }

    private func selectableRow(
        title: String,
        isSelected: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.medium))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).playerMenuRowSecondary()
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    private func delayRow(
        title: String,
        value: TimeInterval,
        firstSlot: Int,
        onAdjust: @escaping (TimeInterval) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.medium))
                Spacer()
                Text(Self.delayLabel(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                stepButton("−500 ms", slot: firstSlot + 0) { onAdjust(-0.5) }
                stepButton("−50 ms", slot: firstSlot + 1) { onAdjust(-0.05) }
                stepButton("Reset", slot: firstSlot + 2, action: onReset)
                stepButton("+50 ms", slot: firstSlot + 3) { onAdjust(0.05) }
                stepButton("+500 ms", slot: firstSlot + 4) { onAdjust(0.5) }
            }
        }
    }

    private func stepButton(_ title: String, slot: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium))
        }
        .focused($focus, equals: .row(slot))
    }

    // MARK: Model helpers

    /// Track controls, left→right: Speed · Audio · **Subtitles** (Subtitles at the
    /// far-right edge), rendered on the right of the button row opposite the
    /// left-hand utility cluster (Info · Diagnostics).
    ///
    /// A/V Sync is intentionally omitted for now — the standalone button was
    /// removed. `Category.sync` + `syncPane` are kept so it can be restored later.
    private var availableCategories: [Category] {
        var result: [Category] = []
        if model.engineCapabilities.contains(.playbackSpeed) {
            result.append(.speed)
        }
        if !model.audioOptions.isEmpty
            || model.engineCapabilities.contains(.dialogEnhance) {
            result.append(.audio)
        }
        if model.hasSelectableSubtitles {
            result.append(.subtitles)
        }
        return result
    }

    /// Focus target when the bar first takes focus: Subtitles (the most-used
    /// control) when present, otherwise the first category, otherwise the
    /// always-present Info button.
    private var initialFocus: FocusSlot {
        if availableCategories.contains(.subtitles) { return .button(.subtitles) }
        if let first = availableCategories.first { return .button(first) }
        return .button(.info)
    }

    private struct TrackRow: Identifiable {
        let id: Int
        let header: String?
        let title: String
        let subtitle: String
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
                subtitle: "",
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
                subtitle: "",
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
                title: "Dialog Enhance",
                subtitle: "Boost speech clarity in loud mixes",
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
        case .info:
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
        if openPanel != nil {
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
    static func subtitleSyncHint(_ seconds: TimeInterval) -> String {
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

/// Reports the controls layer's full height up the tree so the Subtitle Style
/// panel can size itself to climb toward the top edge.
private struct ControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the transport block's (scrubber + buttons) height so the Style panel
/// can align its top margin to its side margin.
private struct TransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports each panel's natural (unclipped) content height, **keyed by category**,
/// so the glass box can animate ONLY its clip window to that height. The rows are
/// laid out at full size and clipped to the animating frame, so they never
/// cross-fade or spill past the rounded border when a sub-screen adds/removes rows
/// — "animate the container, not what's inside".
///
/// The height is tagged with its owning `Category` because panels overlap during
/// the 0.2s open/close transition: a *closing* panel stays mounted and keeps
/// reporting its (tall) height while the *next* panel is already opening. Keying by
/// category lets the reader pick out only the currently-open panel's height, so a
/// closing panel can never size the panel that's replacing it (which caused short
/// menus like Audio to spawn tall and then animate down).
private struct PanelBodyHeightKey: PreferenceKey {
    static let defaultValue: [PlayerControls.Category: CGFloat] = [:]
    static func reduce(
        value: inout [PlayerControls.Category: CGFloat],
        nextValue: () -> [PlayerControls.Category: CGFloat]
    ) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
private struct ScrubBar: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    /// Horizontal distance from the scrub track's leading/trailing edge out to the
    /// screen edge, so the trickplay thumbnail can extend past the track (but not
    /// off-screen).
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)
            // The bar is "focused" whenever the scrub surface owns focus — the
            // controls are up and focus hasn't dropped to the button row below
            // (scrubbing counts as focused). Focused, the bar is full height,
            // the played fill is bright and the playhead is a rounded pill. Once
            // focus moves to the buttons the bar slims by 8pt, the fill fades and
            // the playhead squares off flush into the track.
            let focused = model.controlsVisible && !model.controlBarVisible
            let barHeight: CGFloat = focused ? 20 : 12
            let knobWidth: CGFloat = focused ? 8 : 4
            let knobHeight: CGFloat = focused ? (model.isScrubbing ? 40 : 32) : barHeight

            ZStack(alignment: .leading) {
                glassTrack(height: barHeight)
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: width * CGFloat(model.bufferedFraction), height: barHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                    .fill(.white.opacity(focused ? 0.62 : 0.32))
                    .frame(width: knobX, height: barHeight)
                RoundedRectangle(cornerRadius: focused ? knobWidth / 2 : 0, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)

                if model.isScrubbing && model.hasPreviewFrame {
                    thumbnailPreview(width: width, knobX: knobX)
                        .transition(.thumbnailDismiss)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation(.easeOut(duration: 0.2), value: model.controlBarVisible)
            .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
        }
    }

    /// The base scrub track rendered as Liquid Glass on tvOS 26+, with a
    /// translucent-fill fallback on older systems.
    @ViewBuilder
    private func glassTrack(height: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .frame(height: height)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: height)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        if let image = model.previewImage {
            // ~15% larger than the previous 420pt thumbnail.
            let thumbWidth: CGFloat = 483
            let aspect = previewAspect
            let thumbHeight = thumbWidth / aspect
            let corner: CGFloat = 18
            let border: CGFloat = 12
            // Account for glass border so visual left edge sits at x=0 (track edge).
            let visualWidth = thumbWidth + 2 * border
            let minX = visualWidth / 2
            let edgeMargin: CGFloat = 16
            let maxX = width + trailingInset - visualWidth / 2 - edgeMargin
            let clampedX = min(max(minX, knobX), max(minX, maxX))

            let content = Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            // Float the trickplay thumbnail above the scrub bar (bar is centred
            // at y=0 in this GeometryReader). `thumbnailLift` is the gap from the
            // bar centre to the *bottom* of the thumbnail — kept tight so the
            // preview hugs the bar.
            let thumbnailLift: CGFloat = 34
            Group {
                if #available(tvOS 26.0, *) {
                    content
                        .padding(border)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner + border, style: .continuous))
                } else {
                    content
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .stroke(.white.opacity(0.85), lineWidth: border)
                        )
                }
            }
            .position(x: clampedX, y: -(thumbnailLift + thumbHeight / 2))
        }
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}

/// The Info-card action-button style: an **instant** focus treatment (no fade).
/// The stock `.glass` / `.borderedProminent` styles animate their own focus
/// highlight, which can't be disabled from outside — so the Info card draws its
/// own capsule and swaps fill/foreground on the same frame focus changes.
/// `.animation(nil, value: focused)` guarantees the swap never rides an ambient
/// transaction. Icon-only at rest; the label reveals with the button on focus
/// (instant, so the row never janks mid-expand).
private struct InfoActionButtonStyle: ButtonStyle {
    let focused: Bool
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = focused ? .white : .white.opacity(prominent ? 0.24 : 0.12)
        let fg: Color = focused ? .black : .white
        return configuration.label
            .foregroundStyle(fg)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Capsule(style: .continuous).fill(fill))
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            // Everything about focus is instant — no background/foreground fade.
            .animation(nil, value: focused)
    }
}

/// Drives the trickplay thumbnail's dismissal: it appears instantly (identity
/// insertion) and, on removal, quickly fades while blurring, scaling down a
/// touch, and drifting slightly downward.
private struct ThumbnailTransitionModifier: ViewModifier {
    /// 0 = fully visible, 1 = fully dismissed.
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .offset(y: 13 * progress)
            .opacity(Double(max(0, 1 - progress * 4.5)))
    }
}

private extension AnyTransition {
    static var thumbnailDismiss: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: ThumbnailTransitionModifier(progress: 1),
                identity: ThumbnailTransitionModifier(progress: 0)
            )
        )
    }
}

private extension View {
    /// Applies the system Liquid Glass button style (tvOS 26+), falling back to
    /// the bordered styles on older systems. `prominent` highlights the active
    /// category / enabled toggle.
    @ViewBuilder
    func playerGlassButton(prominent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// The floating panel's translucent backing. Native **Liquid Glass** on tvOS
/// 26+, falling back to a cheap solid translucent fill below that (and honouring
/// the perf intent on older devices).
///
/// Still **no `.shadow`** — a soft drop shadow was the original frame-drop
/// culprit over Dolby Vision (a per-frame offscreen blur recomposited on the
/// moving HDR signal). A 1px stroke gives edge separation instead. The glass is
/// a *bounded* backdrop sample (the panel is only 760pt wide), so keep an eye on
/// the diagnostics FPS over DV content and fall back to the solid fill if it
/// ever stutters.
private struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 32
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        } else {
            content
                .background(Color.black.opacity(0.8))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// Horizontally positions an open control panel within the bottom cluster.
/// `leadingInset` non-nil → shift the panel right to sit under its own button
/// (Speed); nil → pin to the trailing edge above the track-button cluster
/// (Subtitles/Audio/Sync).
private struct PanelHorizontalPlacement: ViewModifier {
    let leadingInset: CGFloat?

    func body(content: Content) -> some View {
        if let leadingInset {
            // Use `.offset` — NOT `.padding(.leading,)` — so aligning the Speed
            // panel to its button has zero effect on the bottom cluster's layout.
            // Leading padding applied after a fill frame grows the panel's own
            // width by `leadingInset`, overflowing the row and dragging the whole
            // control cluster sideways as the panel opens. Offset only moves the
            // drawn panel; the measured cluster (and the button we align to) stay
            // put, so there's no layout feedback loop.
            content.offset(x: max(0, leadingInset))
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Carries the Speed button's measured leading-edge X up to `PlayerControls` so
/// the Speed panel can align its left edge to the button. Only the Speed button
/// publishes a value; sibling buttons contribute the default (0), so the reduce
/// keeps the largest (the real measurement) rather than letting a 0 clobber it.
private struct SpeedButtonLeadingKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
