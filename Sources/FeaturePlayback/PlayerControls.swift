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

    enum FocusSlot: Hashable {
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
            if !focused {
                focus = nil
                model.isPanelOpen = false
            }
        }
        .onChange(of: focus) { _, _ in
            // Any focus move between control-bar buttons is activity — bump so the
            // container restarts its idle countdown instead of hiding mid-navigation.
            model.controlBarActivity &+= 1
        }
        .onChange(of: openPanel) { _, panel in
            // Surface whether a menu is open so the container pins the transport
            // visible while one is up, and count the open/close as bar activity.
            model.isPanelOpen = panel != nil
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
        .plozzRemoteCommands(
            onExit: handleExit,
            onPlayPause: actions.togglePlayPause,
            onMove: { direction in
                if direction == .up && openPanel == nil { onExitToSurface() }
            }
        )
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
                        .plozzFocusSection()
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
            InfoPanelView(model: model, actions: actions, focus: $focus, onClose: { openPanel = nil })
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
        case .audio: AudioPaneView(rows: audioRows, palette: palette, focus: $focus)
        case .speed: SpeedPaneView(model: model, palette: palette, actions: actions, focus: $focus)
        case .sync: SyncPaneView(model: model, actions: actions, focus: $focus)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
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

    struct TrackRow: Identifiable {
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

#endif
