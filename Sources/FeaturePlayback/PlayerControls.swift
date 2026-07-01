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
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
    /// Apply an edited subtitle **appearance** (from the in-player Style screen):
    /// the host updates the live overlay for instant preview and persists it.
    var setSubtitleStyle: (SubtitleStyle) -> Void = { _ in }
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
        case diagnostics
        case row(Int)
        case edit       // Subtitles header ✎ Edit (appearance) button
        case download   // Trailing "Search for subtitles…" row
        case subBack    // Back control inside a Subtitles sub-screen
    }

    /// Sub-screens of the Subtitles panel. `tracks` is the default list; the
    /// header ✎ Edit opens `style`, and the trailing row opens `download`. Menu
    /// backs a sub-screen out to `tracks` rather than closing the whole panel.
    private enum SubtitleScreen { case tracks, download, style }

    @State private var openPanel: Category?
    @State private var subtitleScreen: SubtitleScreen = .tracks
    @FocusState private var focus: FocusSlot?

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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomCluster
                    .opacity(model.controlsVisible ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
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
                // Panel fully closed. Return focus to whatever transport control
                // opened it (skip while the whole bar is hiding — focus is
                // intentionally cleared then). Then let the title/description
                // fade back in after a short beat rather than snapping in.
                if model.controlBarVisible { restoreFocus(panelReturnFocus) }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    if openPanel == nil { titleVisible = true }
                }
                return
            }
            titleVisible = false
            if panel == .info {
                focus = model.hasNextEpisode ? .infoNext
                    : (model.hasPreviousEpisode ? .infoPrev : .infoRestart)
            } else {
                focus = .row(selectedRowIndex(for: panel))
            }
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
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            scrubberRow
            buttonRow
        }
        .animation(.easeInOut(duration: 0.2), value: openPanel)
        .animation(.easeInOut(duration: 0.28), value: titleVisible)
        .animation(Self.transportFadeAnimation(scrubbing: model.isScrubbing), value: model.isScrubbing)
        .padding(.horizontal, 60)
        .padding(.top, 90)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
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
            // Utility cluster (far left): media Info placeholder + Diagnostics.
            Button {
                toggle(.info)
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: openPanel == .info)
            .focused($focus, equals: .button(.info))

            Button {
                model.diagnosticsEnabled.toggle()
            } label: {
                Label(
                    "Diagnostics",
                    systemImage: model.diagnosticsEnabled ? "waveform.circle.fill" : "waveform.circle"
                )
                .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: model.diagnosticsEnabled)
            .focused($focus, equals: .diagnostics)

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
    /// When a panel closes, its focused row is removed in the same state update
    /// and tvOS's focus engine auto-recovers to the leftmost control (the Info
    /// button). Writing @FocusState synchronously here fights that recovery, and
    /// writing it *twice* (sync + deferred) makes two buttons briefly render
    /// focused. A SINGLE deferred write on the next runloop tick lands cleanly and
    /// returns focus to wherever the panel was opened — no matter how deep its
    /// sub-screens went.
    private func restoreFocus(_ slot: FocusSlot?) {
        guard let slot else { return }
        DispatchQueue.main.async { focus = slot }
    }

    // MARK: Panels

    @ViewBuilder
    private func panelContainer(for category: Category) -> some View {
        if category == .info {
            infoPanel
                .colorScheme(.dark)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader(for: category)
                Divider().background(.white.opacity(0.15))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch category {
                        case .subtitles: subtitleBody
                        case .audio: audioPane
                        case .speed: speedPane
                        case .sync: syncPane
                        case .info: EmptyView()
                        }
                    }
                    .padding(.vertical, 10)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: isStyleScreen(category) ? styleScreenContentHeight : nil,
                        alignment: .topLeading
                    )
                }
                .frame(maxHeight: isStyleScreen(category) ? styleScreenContentHeight : 440)
            }
            .frame(width: 520, alignment: .leading)
            .colorScheme(.dark)
            .modifier(PanelGlassBackground())
            // The track controls live on the right of the button row, so the panel
            // opens against the trailing edge above them rather than on the left.
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func isStyleScreen(_ category: Category) -> Bool {
        category == .subtitles && subtitleScreen == .style
    }

    /// Height the Subtitle Style scroll area is pinned to so the panel climbs
    /// toward the top edge, leaving a top margin roughly matching the panel's
    /// ~60pt side margin while its bottom stays anchored above the scrubber. The
    /// reserve covers the bottom chrome (scrubber + button row + paddings), the
    /// panel header, and that target top margin; it clamps so short screens still
    /// render if the height hasn't been measured yet.
    private var styleScreenContentHeight: CGFloat {
        guard availableHeight > 0 else { return 440 }
        return max(360, availableHeight - 360)
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
    private var infoPanel: some View {
        // Concentric radii, matching the app's cards: the thumbnail's media radius
        // nested inside the card's glass radius (outer = inner + content padding),
        // so both corners share a centre.
        let thumbRadius = PlozzTheme.Metrics.mediumMediaCornerRadius
        let contentPad: CGFloat = 24
        let cardRadius = thumbRadius + contentPad
        let thumbHeight: CGFloat = 210

        return HStack(alignment: .top, spacing: 28) {
            infoThumbnail(cornerRadius: thumbRadius, height: thumbHeight)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.infoHeadline.isEmpty ? "Now Playing" : model.infoHeadline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !model.overview.isEmpty {
                    Text(model.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
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

            VStack(alignment: .trailing, spacing: 12) {
                if model.hasNextEpisode {
                    infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                        actions.playNextEpisode()
                    }
                }
                if model.hasPreviousEpisode {
                    infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                        actions.playPreviousEpisode()
                    }
                }
                infoActionButton(title: "Restart", icon: "arrow.counterclockwise", prominent: false, slot: .infoRestart) {
                    actions.restart()
                    openPanel = nil   // focus restored centrally in onChange(of: openPanel)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(contentPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: cardRadius))
    }

    private func infoThumbnail(cornerRadius: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: height * 16.0 / 9.0, height: height)
            .overlay {
                FallbackAsyncImage(urls: model.artworkURLs) {
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

    private func infoActionButton(
        title: String,
        icon: String,
        prominent: Bool,
        slot: FocusSlot,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .playerGlassButton(prominent: prominent)
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
                    openSubtitleScreen(.tracks)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                }
                .playerGlassButton(prominent: false)
                .focused($focus, equals: .subBack)
            }
            Text(headerTitle(for: category))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if category == .subtitles && subtitleScreen == .tracks {
                Button {
                    openSubtitleScreen(.style)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .playerGlassButton(prominent: false)
                .focused($focus, equals: .edit)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private func headerTitle(for category: Category) -> String {
        guard category == .subtitles else { return category.title }
        switch subtitleScreen {
        case .tracks: return "Subtitles"
        case .download: return "Download Subtitles"
        case .style: return "Subtitle Style"
        }
    }

    /// The Subtitles panel is a small master flow: the track list (default), a
    /// Download screen (from the trailing row) and a Style screen (from ✎ Edit).
    @ViewBuilder
    private var subtitleBody: some View {
        switch subtitleScreen {
        case .tracks: subtitlePane
        case .download: subtitleDownloadStub
        case .style: subtitleStyleEditor
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
            downloadEntryRow
        }
        .padding(.horizontal, 14)
    }

    /// "Looked through them all, found nothing → get more." Kept at the END of
    /// the list so it surfaces exactly when it's needed (few / no tracks) and
    /// stays out of the way when there are many.
    private var downloadEntryRow: some View {
        Button {
            openSubtitleScreen(.download)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.body)
                Text("Search for subtitles…").font(.body).lineLimit(1)
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

    // MARK: Subtitles sub-screens (Download stub / live Style editor)

    private var subtitleDownloadStub: some View {
        subScreenStub(message: "Search the server's providers for a subtitle in your language and load it right here.")
    }

    /// The live subtitle-appearance editor, hosted over the running video so every
    /// tweak previews instantly on the real subtitles behind the panel. Rows use
    /// the same steppers / focus language as the other in-player menus. Edits are
    /// funnelled through `updateStyle`, which routes to `actions.setSubtitleStyle`
    /// (live overlay + profile persistence). Back lives in the panel header.
    @ViewBuilder
    private var subtitleStyleEditor: some View {
        let style = model.subtitleStyle
        VStack(alignment: .leading, spacing: 2) {
            styleStepperRow(
                title: "Text Size",
                options: Self.sizeOptions,
                selection: Int((style.fontScale * 100).rounded()),
                label: { "\($0)%" }
            ) { pct in updateStyle { $0.fontScale = Double(pct) / 100 } }

            styleStepperRow(
                title: "Position",
                options: Self.positionOptions,
                selection: Int((style.verticalPosition * 100).rounded()),
                label: Self.positionLabel
            ) { pct in updateStyle { $0.verticalPosition = Double(pct) / 100 } }

            styleStepperRow(
                title: "Opacity",
                options: Self.opacityOptions,
                selection: Int((style.opacity * 100).rounded()),
                label: { "\($0)%" }
            ) { pct in updateStyle { $0.opacity = Double(pct) / 100 } }

            styleStepperRow(
                title: "Text Colour",
                options: Self.textColorOptions,
                selection: style.textColor,
                label: Self.colorLabel
            ) { color in updateStyle { $0.textColor = color } }

            styleStepperRow(
                title: "Outline",
                options: SubtitleEdgeStyle.allCases,
                selection: style.edge.style,
                label: { $0.displayName }
            ) { edge in updateStyle { $0.edge.style = edge } }

            styleToggleRow(
                title: "Background Box",
                isOn: style.background.isEnabled,
                slot: Self.styleBoxSlot
            ) {
                updateStyle { s in
                    s.background.isEnabled.toggle()
                    if s.background.isEnabled && !Self.boxColorOptions.contains(s.background.color) {
                        s.background.color = Self.boxColorOptions[0]
                    }
                }
            }

            if style.background.isEnabled {
                styleStepperRow(
                    title: "Box Colour",
                    options: Self.boxColorOptions,
                    selection: Self.boxColorOptions.contains(style.background.color) ? style.background.color : Self.boxColorOptions[0],
                    label: Self.boxColorLabel
                ) { color in updateStyle { $0.background.color = color } }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Subtitle style editor rows + option sets

    /// One appearance row: a leading title and a trailing compact stepper, matching
    /// the Speed menu's stepper language (circular focus thumb). The stepper snaps
    /// the current value to the nearest listed option so a legacy value off-grid
    /// still shows and steps cleanly.
    private func styleStepperRow<V: Hashable>(
        title: String,
        options: [V],
        selection current: V,
        label: @escaping (V) -> String,
        apply: @escaping (V) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            SettingsStepper(
                options: options,
                selection: Binding(
                    get: { options.contains(current) ? current : (options.first ?? current) },
                    set: { apply($0) }
                ),
                compact: true,
                title: label
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// A button-based on/off row (NOT a SwiftUI `Toggle`) so it flips on Select and
    /// wears the same fitted-white-card focus as every other menu row.
    private func styleToggleRow(
        title: String,
        isOn: Bool,
        slot: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(slot))
    }

    /// Reads the mirror, applies the mutation, and routes the result through the
    /// live-apply + persist funnel. Single write path for every appearance control.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        var next = model.subtitleStyle
        mutate(&next)
        actions.setSubtitleStyle(next)
    }

    // Precise, numeric option grids (percentages) — no "low / high" buckets.
    private static let sizeOptions: [Int] = Array(stride(from: 60, through: 250, by: 5))
    private static let positionOptions: [Int] = Array(stride(from: 0, through: 90, by: 5))
    private static let opacityOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    private static let textColorOptions: [SubtitleColor] = SubtitleColor.presets.map(\.color)
    private static let boxColorOptions: [SubtitleColor] = [
        SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.65),
        SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.7),
        SubtitleColor(red: 1, green: 1, blue: 1, alpha: 0.75)
    ]
    /// Focus slot for the Background Box toggle — parked high so it never collides
    /// with the track-list `.row(index)` slots reused across panes.
    private static let styleBoxSlot = 90

    /// 0% = seated at the bottom safe edge; 90% = near the top. Anchors are named
    /// so the extremes read clearly, but every step in between is a plain percent.
    private static func positionLabel(_ pct: Int) -> String {
        switch pct {
        case 0: return "Bottom"
        case 90: return "Top"
        default: return "\(pct)%"
        }
    }

    private static func colorLabel(_ color: SubtitleColor) -> String {
        SubtitleColor.presets.first(where: { $0.color == color })?.name ?? "Custom"
    }

    private static func boxColorLabel(_ color: SubtitleColor) -> String {
        switch boxColorOptions.firstIndex(of: color) {
        case 0: return "Black"
        case 1: return "Charcoal"
        case 2: return "White"
        default: return "Custom"
        }
    }

    private func subScreenStub(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Text("Coming soon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSubtitleScreen(_ screen: SubtitleScreen) {
        subtitleScreen = screen
        switch screen {
        case .tracks: focus = .row(selectedRowIndex(for: .subtitles))
        case .download, .style: focus = .subBack
        }
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
        if model.hasSelectableAudio
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
    /// always-present Diagnostics button.
    private var initialFocus: FocusSlot {
        if availableCategories.contains(.subtitles) { return .button(.subtitles) }
        if let first = availableCategories.first { return .button(first) }
        return .diagnostics
    }

    private struct TrackRow: Identifiable {
        let id: Int
        let header: String?
        let title: String
        let subtitle: String
        let isSelected: Bool
        let isToggle: Bool
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
                action: { actions.selectSubtitle(option.id) }
            )
        }
    }

    /// Audio menu rows: selectable tracks followed by the Dialog Enhance toggle
    /// when supported. Indexed from 0 in their own focus-slot space.
    private var audioRows: [TrackRow] {
        var rows: [TrackRow] = []
        var index = 0
        if model.hasSelectableAudio {
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
            openSubtitleScreen(.tracks)
            return
        }
        if openPanel != nil {
            openPanel = nil   // onChange(of: openPanel) restores the transport focus
        } else {
            onExitToSurface()
        }
    }

    // MARK: Formatting

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

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
        let ms = Int((seconds * 1000).rounded())
        if ms == 0 { return "0 ms" }
        return ms > 0 ? "+\(ms) ms" : "\(ms) ms"
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
    var cornerRadius: CGFloat = 24
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
#endif
