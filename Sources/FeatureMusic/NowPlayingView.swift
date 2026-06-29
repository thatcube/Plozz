#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The full-screen Now Playing surface: large artwork, track/artist/album, a
/// quality badge, a full-width analog Liquid Glass scrub bar with the play/pause
/// button beside it, and a row of equally-sized Liquid Glass transport buttons
/// below. Single centered column — no Up Next list. Observes the shared
/// `AudioPlaybackController`.
struct NowPlayingView: View {
    @Bindable var controller: AudioPlaybackController
    /// The app's currently selected theme, passed in from the host so the
    /// player's "Match Theme" appearance can distinguish OLED from plain Dark
    /// (the system color scheme alone can't tell them apart).
    var appTheme: AppTheme = .system
    /// Per-profile player preferences (appearance + "show extra info"), injected
    /// from the host so each profile keeps its own choice.
    let musicPlayer: MusicPlayerSettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubModel = MusicScrubModel()

    /// Prominent colors of the current track's artwork, driving the morphing
    /// liquid background. Recomputed whenever the track changes.
    @State private var artworkPalette: [Color] = []

    /// Whether the bottom control bar is currently shown. It auto-hides after a
    /// spell of no interaction so only the artwork, title/album and lyrics
    /// remain, and slides back on any remote activity.
    @State private var controlsVisible = true
    /// Pending auto-hide; cancelled/rescheduled on every interaction.
    @State private var hideTask: Task<Void, Never>?

    /// True while the control bar is mid slide-in/out. During the slide the
    /// scrub bar suppresses its progress spring so the fill + knob ride the slide
    /// in lockstep with the glass track (rather than picking up a separate easing
    /// from playback ticks).
    @State private var controlsSliding = false

    /// Measured height of the bottom control bar, so it can slide fully off the
    /// bottom edge (as one persistent layer) instead of being inserted/removed —
    /// keeping the glass scrub track, played fill and knob moving in lockstep with
    /// the rest of the bar.
    @State private var bottomBarHeight: CGFloat = 0

    /// Focus targets on the player. Play/pause is the anchor the bar always
    /// comes back focused on; the reveal catcher holds focus while the bar is
    /// hidden so tvOS focus never lands on an invisible control. Every visible
    /// control has its own case so *any* focus movement between them resets the
    /// auto-hide timer (the bar only fades after a true idle spell).
    private enum Focus: Hashable {
        case playPause, shuffle, previous, next, repeatMode, lyrics, revealCatcher
    }
    @FocusState private var focus: Focus?

    /// Seconds of inactivity before the control bar fades away.
    private static let controlsAutoHideDelay: TimeInterval = 5

    /// Whether the user wants the lyrics panel shown. Persisted (default on) so
    /// the choice is remembered across sessions. The toggle is disabled — and so
    /// can't be changed — when the current track has no lyrics.
    @AppStorage(MusicLyricsPreference.storageKey) private var lyricsEnabled = MusicLyricsPreference.defaultEnabled

    /// Whether the player shows extra track detail — album name, audio
    /// quality/format, and the lyrics source. Off by default to keep the screen
    /// clean (it's a niche audiophile detail); toggled from Settings ▸ Appearance
    /// and remembered per profile.
    private var showTrackDetails: Bool { musicPlayer.showTrackDetails }

    /// The player's chosen background look (Settings ▸ Appearance ▸ Music
    /// Player). Defaults to following the app theme.
    private var playerAppearance: MusicPlayerAppearance { musicPlayer.appearance }
    /// The app's current light/dark resolution, read from the environment the
    /// player is presented in — used only when `playerAppearance` is `.matchTheme`.
    @Environment(\.colorScheme) private var systemColorScheme

    /// The latched decision of whether to reserve the lyrics panel. It is held
    /// steady across the brief `.loading` window after a track change so the
    /// artwork doesn't fly to center and then jump back when the next song also
    /// has lyrics.
    ///
    /// `nil` means "not decided for any track yet" — on first open we fall back to
    /// the live state, so the player opens **centered** unless we already *know*
    /// the track has lyrics (already resolved `.loaded`), in which case the panel
    /// shows immediately with no slide. Once a track resolves we latch a concrete
    /// value and only ever change it on the next *definitive* result
    /// (`.loaded`/`.unavailable`) or when the user toggles lyrics — never during
    /// `.loading`. So a song→song hand-off where both have lyrics never moves the
    /// artwork, while moving to a song without lyrics waits for the lookup to
    /// finish, then centers.
    @State private var latchedShowsLyricsPanel: Bool?

    /// Pending "collapse the panel because lyrics are unavailable" timer. Held in
    /// state so a follow-on `.loaded` result (e.g. the user skipping to the next
    /// track) can cancel the collapse before the message even has time to fade.
    @State private var pendingCollapse: Task<Void, Never>?

    /// How long the "No lyrics found" message stays visible before the panel
    /// collapses, so anyone reading the panel actually gets time to see it
    /// rather than catching a flash mid-animation.
    private static let noLyricsDwell: Duration = .milliseconds(1500)

    /// Whether to reserve the lyrics panel next to the player. Falls back to the
    /// live state only until the first track resolves (see `latchedShowsLyricsPanel`).
    private var showsLyricsPanel: Bool {
        latchedShowsLyricsPanel ?? (lyricsEnabled && controller.lyricsState.hasLyrics)
    }

    /// Recomputes the latched panel decision from a *definitive* lyrics result.
    /// `.loading` is deliberately ignored so the layout holds steady during the
    /// lookup — that hold is the "wait" before any artwork animation. Disabling
    /// lyrics always collapses the panel immediately.
    private func updateLyricsPanelLatch() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        guard lyricsEnabled else {
            latchedShowsLyricsPanel = false
            return
        }
        switch controller.lyricsState {
        case .loaded:
            latchedShowsLyricsPanel = true
        case .unavailable:
            // If the panel is currently open we hold it open for a beat so the
            // "No lyrics found" message has time to be read before the panel
            // slides shut. From a closed/undecided state we just collapse
            // immediately — there's nothing for the user to read in that case.
            if latchedShowsLyricsPanel == true {
                pendingCollapse = Task { @MainActor in
                    try? await Task.sleep(for: Self.noLyricsDwell)
                    guard !Task.isCancelled else { return }
                    if case .unavailable = controller.lyricsState, lyricsEnabled {
                        latchedShowsLyricsPanel = false
                    }
                    pendingCollapse = nil
                }
            } else {
                latchedShowsLyricsPanel = false
            }
        case .idle, .silent:
            // `.silent` means we already know this track has no lyrics (cache
            // hit) and a background re-check is quietly under way. Behave
            // exactly like `.idle` — no panel, no message, no dwell — so the
            // user never sees a "Searching for lyrics…" / "No lyrics found"
            // flash for a song they've played before.
            latchedShowsLyricsPanel = false
        case .loading:
            break
        }
    }

    var body: some View {
        ZStack {
            background

            // Drives the scrub model from the 4x/sec playback clock in isolation,
            // so playback ticks no longer re-evaluate the whole player body. (See
            // PlaybackClock.) Always mounted so progress stays current even while
            // the controls are hidden.
            PlaybackClock(controller: controller, model: scrubModel)

            // Main content + bottom bar share the ZStack. The bar stays mounted
            // and its two groups (scrub bar / transport buttons) each slide off
            // the bottom edge via offset/opacity (rather than an insert/remove
            // transition). Each group moves as one persistent layer — so the glass
            // scrub track, played fill and knob (which live inside a GeometryReader
            // that wouldn't inherit a .move transition) travel together — and the
            // two groups are staggered slightly for a layered settle.
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 80)
                .padding(.top, 60)
                // Reserve room for the bar while it's shown so the artwork and
                // lyrics center in the space *above* the controls, then re-center
                // on the full screen once the bar slides away.
                .padding(.bottom, controlsVisible ? bottomBarHeight : 0)

            bottomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(controlsVisible)

            // While the bar is hidden, a transparent full-screen catcher takes
            // focus so a Select/click brings the controls back. It uses a fully
            // custom button style that renders *only* its (clear) label, so tvOS
            // never draws a focus highlight plate over the screen.
            if !controlsVisible {
                Button { showControls() } label: { Color.clear }
                    .buttonStyle(InvisibleButtonStyle())
                    .focused($focus, equals: .revealCatcher)
                    .onMoveCommand { _ in showControls() }
            }
        }
        // mainContent's bottom-padding re-center still rides one shared spring;
        // each bar group drives its own (staggered) slide inside bottomControls.
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: controlsVisible)
        .onChange(of: controlsVisible) { _, _ in
            // Mark the slide window so the scrub bar holds its progress spring
            // until the bar has settled (see controlsSliding).
            controlsSliding = true
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                controlsSliding = false
            }
        }
        .onPreferenceChange(BottomBarHeightKey.self) { height in
            bottomBarHeight = height
        }
        .onAppear {
            syncScrubModel()
            setIdleTimerDisabled(true)
            showControls()
            // Seed the latch from the track we opened on, so a track we already
            // know has lyrics shows the panel immediately (no open-time slide),
            // while an unresolved/none track opens centered.
            updateLyricsPanelLatch()
        }
        .onDisappear {
            setIdleTimerDisabled(false)
            hideTask?.cancel()
        }
        .onChange(of: scrubModel.isScrubbing) { _, _ in scheduleHide() }
        // Any focus movement among the controls (or onto the scrub bar, which
        // clears `focus`) is a live interaction, so restart the idle countdown —
        // the bar only fades 5s after the *last* thing the user did.
        .onChange(of: focus) { _, _ in
            if controlsVisible { scheduleHide() }
        }
        .task(id: controller.currentTrack?.id) { await loadArtworkPalette() }
        // Re-evaluate the lyrics-panel layout only on a *definitive* result (or a
        // toggle change), holding it steady through `.loading` so the artwork
        // doesn't fly to center and snap back between two songs that both have
        // lyrics. See `latchedShowsLyricsPanel`.
        .onChange(of: controller.lyricsState) { _, _ in updateLyricsPanelLatch() }
        .onChange(of: lyricsEnabled) { _, _ in updateLyricsPanelLatch() }
        // Back/Menu first dismisses the controls if they're showing; pressing it
        // again (with the controls already hidden) closes the player.
        .onExitCommand {
            if controlsVisible {
                hideControls()
            } else {
                dismiss()
            }
        }
        // In the foreground the Siri Remote's play/pause press is delivered
        // through the focus/responder chain, not MPRemoteCommandCenter — so the
        // command center alone resumes inconsistently. Handle it here so the
        // hardware button reliably toggles playback while the player is open,
        // and reveal the controls so the user sees the state change.
        .onPlayPauseCommand {
            controller.togglePlayPause()
            showControls()
        }
        // The player paints its own background, so it never blindly inherits the
        // app theme. It resolves its own look (see `playerStyle`) and forces the
        // subtree's color scheme to match so text and glass read correctly —
        // light-on-dark for Vibrant Dark / OLED, dark-on-light for Frosted Light.
        .environment(\.colorScheme, isLightPlayer ? .light : .dark)
    }

    /// The resolved background treatment, collapsing `.matchTheme` against the
    /// app's selected theme (so OLED → true black, Light → frosted, etc.).
    private var playerStyle: LiquidArtworkBackground.Style {
        switch playerAppearance {
        case .matchTheme: return matchedThemeStyle
        case .dark: return .dark
        case .light: return .light
        case .oled: return .oled
        }
    }

    /// Maps the app's `AppTheme` onto a player look for the "Match Theme" option.
    /// `.system` has no explicit light/dark, so it follows the resolved system
    /// color scheme.
    private var matchedThemeStyle: LiquidArtworkBackground.Style {
        switch appTheme {
        case .light: return .light
        case .dark: return .dark
        case .oled: return .oled
        case .system: return systemColorScheme == .light ? .light : .dark
        }
    }

    /// Whether the resolved player look is the light one (drives text color).
    private var isLightPlayer: Bool { playerStyle == .light }

    /// A button style that renders only its label with no platform focus
    /// decoration. Used for the full-screen reveal catcher so taking focus while
    /// the controls are hidden never paints a white highlight plate.
    private struct InvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    /// The centered content that stays on screen even after the controls hide:
    /// artwork + title/album on the left, lyrics on the right when present.
    private var mainContent: some View {
        HStack(alignment: .center, spacing: 56) {
            metaColumn
                .frame(maxWidth: showsLyricsPanel ? 620 : 760)
            if showsLyricsPanel {
                LyricsPanel(controller: controller, showTrackDetails: showTrackDetails)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: showsLyricsPanel)
    }

    /// Reveals the control bar and (re)arms the auto-hide timer, focusing
    /// play/pause so the bar always returns with it highlighted.
    private func showControls() {
        controlsVisible = true
        focus = .playPause
        scheduleHide()
    }

    /// Immediately hides the control bar (cancelling the pending auto-hide) and
    /// moves focus to the reveal catcher, exactly as the auto-hide timer would.
    private func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
        focus = .revealCatcher
    }

    /// Schedules the control bar to fade away after `controlsAutoHideDelay`,
    /// cancelling any previously scheduled hide. Stays up while the user is
    /// actively scrubbing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.controlsAutoHideDelay))
            guard !Task.isCancelled else { return }
            if scrubModel.isScrubbing {
                scheduleHide()
                return
            }
            controlsVisible = false
            focus = .revealCatcher
        }
    }

    /// Keeps the Apple TV awake while the full-screen player is open so synced
    /// lyrics keep scrolling and artwork stays up during long, hands-off listens.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// The artwork + title/artist block. By default it shows only the title and
    /// artist (the clean, Apple Music-style minimum); album and the audio
    /// quality badge appear only when "Show track details" is enabled in
    /// Settings. Stays on screen after the controls auto-hide.
    private var metaColumn: some View {
        VStack(spacing: 32) {
            MusicArtworkImage(
                url: controller.currentTrack?.artworkURL,
                systemPlaceholder: "music.note",
                cornerRadius: 16,
                showsMediaEdge: false,
                asyncFallbackURL: trackFallback(controller.currentTrack)
            )
                .frame(width: 420, height: 420)
                .shadow(radius: 30)

            trackTextBlock
                // Reserve a constant height for the text so the artwork above it
                // never shifts when the next track's text differs — a 1- vs 2-line
                // title, a missing album, or no quality badge. Top aligned, so any
                // slack falls *below* the text and the artwork stays put; that's
                // what makes switching tracks seamless. The height depends only on
                // whether the extra-info rows are shown (album + quality badge),
                // never on the individual track, so within a setting it's stable.
                // The constants below assume the explicit font sizes in
                // `trackTextBlock`/`qualityBadge` — update them together.
                .frame(height: showTrackDetails ? 236 : 156, alignment: .top)
                .frame(maxWidth: .infinity)
        }
    }

    /// The title/artist (+ album & quality badge when "show track details" is on)
    /// stack rendered inside `metaColumn`'s reserved-height slot. The album row is
    /// always rendered (transparent when empty) and the quality badge reserves a
    /// constant height, so a track that lacks either doesn't change the layout —
    /// only its visibility changes.
    private var trackTextBlock: some View {
        VStack(spacing: 10) {
            Text(controller.currentTrack?.title ?? "Not Playing")
                .font(.system(size: 46, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: .black.opacity(isLightPlayer ? 0 : 0.4), radius: 8, y: 2)
            if let artist = controller.currentTrack?.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(isLightPlayer ? 0 : 0.35), radius: 6, y: 2)
            }
            if showTrackDetails {
                let album = controller.currentTrack?.albumTitle ?? ""
                Text(album.isEmpty ? " " : album)
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .opacity(album.isEmpty ? 0 : 1)
                    .shadow(color: .black.opacity(isLightPlayer ? 0 : 0.3), radius: 5, y: 2)
                qualityBadge
            }
        }
    }

    /// The full-width transport bar across the bottom, over a soft scrim so it
    /// stays legible against the artwork colors. The scrim flips to white for the
    /// frosted-light look so it lightens rather than darkens the controls area.
    private var bottomControls: some View {
        let slide = bottomBarHeight + 60
        let reveal = Animation.spring(response: 0.5, dampingFraction: 0.86)
        // Buttons trail the scrub bar by a hair so the two groups settle in
        // layers rather than as one slab — each group still moves as a unit.
        let buttonStagger = 0.07
        return VStack(spacing: 24) {
            scrubRow
                .offset(y: controlsVisible ? 0 : slide)
                .opacity(controlsVisible ? 1 : 0)
                .animation(reveal, value: controlsVisible)
            transportRow
                .offset(y: controlsVisible ? 0 : slide)
                .opacity(controlsVisible ? 1 : 0)
                .animation(reveal.delay(controlsVisible ? buttonStagger : 0), value: controlsVisible)
        }
        .padding(.horizontal, 80)
        .padding(.top, 48)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity)
        // Measure the bar's natural height so each group can slide fully clear of
        // the bottom edge. Offsets don't change the reported size, so this stays
        // stable whether the bar is shown or hidden.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BottomBarHeightKey.self, value: proxy.size.height)
            }
        )
        .background(
            LinearGradient(
                colors: [.clear, (isLightPlayer ? Color.white : Color.black).opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .offset(y: controlsVisible ? 0 : slide)
            .opacity(controlsVisible ? 1 : 0)
            .animation(reveal, value: controlsVisible)
        )
    }

    private func syncScrubModel() {
        scrubModel.duration = controller.duration
        if !scrubModel.isScrubbing { scrubModel.currentSeconds = controller.currentTime }
        scrubModel.onCommit = { target in
            Task { await controller.seek(to: target) }
        }
    }

    @ViewBuilder
    private var background: some View {
        LiquidArtworkBackground(palette: artworkPalette, animate: !reduceMotion, style: playerStyle)
    }

    /// Loads the current track's artwork (reusing the shared decoded-image cache)
    /// and extracts its prominent colors off the main thread to feed the morphing
    /// background. Clears to the neutral field when there's no artwork.
    private func loadArtworkPalette() async {
        #if canImport(UIKit)
        guard let url = controller.currentTrack?.artworkURL else {
            artworkPalette = []
            return
        }
        guard let image = await ArtworkImageCache.shared.image(for: url) else { return }
        let colors = await Task.detached(priority: .utility) {
            ArtworkColorExtractor.palette(from: image, maxColors: 5)
        }.value
        guard controller.currentTrack?.artworkURL == url else { return }
        artworkPalette = colors
        #endif
    }

    @ViewBuilder
    private var qualityBadge: some View {
        Group {
            if let quality = controller.currentQuality {
                HStack(spacing: 5) {
                    Image(systemName: quality.isDirectPlay ? "waveform" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text(quality.headline)
                        .font(.system(size: 11, weight: .semibold))
                    if let detail = quality.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(qualityTint.opacity(0.6), lineWidth: 1))
                .foregroundStyle(qualityTint)
            }
        }
        // Reserve a constant height even when there's no quality info, so a track
        // that lacks a badge keeps the same layout as one that has it — see the
        // reserved text slot in `metaColumn`.
        .frame(height: 26)
        .padding(.top, 4)
    }

    private var qualityTint: Color {
        guard let quality = controller.currentQuality else { return .secondary }
        if !quality.isDirectPlay { return .orange }
        return quality.isLossless ? .green : .primary
    }

    /// The full-width analog scrub bar with elapsed / remaining times. Play/pause
    /// no longer sits beside it — it's the big round button centered in the
    /// transport row below.
    private var scrubRow: some View {
        VStack(spacing: 10) {
            MusicScrubBar(model: scrubModel, suppressProgressAnimation: controlsSliding)
                .frame(height: 44)
            HStack {
                Text(MusicFormat.duration(scrubModel.displaySeconds))
                Spacer()
                Text(MusicFormat.duration(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The transport row: the big round play/pause sits dead-centre (aligned with
    /// the album art above it) with previous/next flanking it. Shuffle is pinned
    /// left and repeat + lyrics pinned right via equal-width side containers, so
    /// the asymmetric side clusters never pull the centre group off-centre. Every
    /// button carries a Focus case so moving between them keeps the bar awake.
    private var transportRow: some View {
        HStack(spacing: 0) {
            // Left cluster, pinned leading in a flexible container.
            HStack(spacing: 28) {
                transportButton(
                    icon: "shuffle",
                    tint: controller.isShuffled ? Color.accentColor : .primary
                ) { controller.toggleShuffle() }
                    .focused($focus, equals: .shuffle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Centre group — symmetric, so play/pause lands on the screen centre.
            HStack(spacing: 28) {
                transportButton(icon: "backward.end.fill") { controller.previous() }
                    .focused($focus, equals: .previous)

                playPauseButton

                transportButton(icon: "forward.end.fill") { controller.next() }
                    .focused($focus, equals: .next)
            }

            // Right cluster, pinned trailing in a flexible container of equal
            // width to the left one, keeping the centre group centred.
            HStack(spacing: 28) {
                transportButton(
                    icon: repeatIcon,
                    tint: controller.repeatMode == .off ? .primary : Color.accentColor
                ) { controller.cycleRepeatMode() }
                    .focused($focus, equals: .repeatMode)

                lyricsToggleButton
                    .focused($focus, equals: .lyrics)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The big, round, centred play/pause button — about twice the size of the
    /// other transport controls so it reads as the primary action.
    private var playPauseButton: some View {
        Button {
            controller.togglePlayPause()
            scheduleHide()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 46, weight: .semibold))
                .frame(width: 104, height: 104)
                .contentShape(Circle())
        }
        .musicGlassButton(prominent: true)
        .clipShape(Circle())
        .focused($focus, equals: .playPause)
    }

    /// Toggles the lyrics panel. Highlighted when on; disabled (and dimmed) while
    /// the current track has no lyrics, so it can't be turned on for nothing.
    private var lyricsToggleButton: some View {
        let hasLyrics = controller.lyricsState.hasLyrics
        return transportButton(
            icon: lyricsEnabled ? "quote.bubble.fill" : "quote.bubble",
            tint: (lyricsEnabled && hasLyrics) ? Color.accentColor : .primary
        ) {
            lyricsEnabled.toggle()
        }
        .disabled(!hasLyrics)
        .opacity(hasLyrics ? 1 : 0.4)
    }

    /// A secondary transport control. Its glass button style is **constant** —
    /// active/inactive state is conveyed only by `tint`, never by swapping to a
    /// prominent style. Switching button styles dynamically changes the view's
    /// identity, which on tvOS drops focus (bouncing it to the scrub bar), so the
    /// style must stay fixed for these toggles.
    private func transportButton(
        icon: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            scheduleHide()
            action()
        } label: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .musicGlassButton(prominent: false)
    }

    private var repeatIcon: String {
        switch controller.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// Best-effort album-cover fallback for `track`, used only when the server
    /// ships no artwork. `nil` track / blank fields yield no fallback.
    private func trackFallback(_ track: MusicTrack?) -> (@Sendable () async -> URL?)? {
        guard let track else { return nil }
        return MusicArtworkFallback.trackCover(
            title: track.title,
            album: track.albumTitle,
            artist: track.artistName
        )
    }
}

// MARK: - Lyrics panel

/// Isolates the lyrics' per-tick `currentTime` read. `AudioPlaybackController` is
/// `@Observable`, so SwiftUI tracks property reads per view body: by reading
/// `currentTime` here (instead of in `NowPlayingView.body`) only the lyrics column
/// — which inherently needs the playback position to highlight + auto-scroll —
/// re-renders on each 4x/sec tick, not the artwork, meta, transport buttons (and
/// their glass effects), equalizer or background.
private struct LyricsPanel: View {
    let controller: AudioPlaybackController
    let showTrackDetails: Bool

    var body: some View {
        NowPlayingLyricsView(
            state: controller.lyricsState,
            currentTime: controller.currentTime,
            showTrackDetails: showTrackDetails
        )
    }
}

/// A zero-size, non-interactive sink that confines the 4x/sec `currentTime` (and
/// `duration`) dependency to itself. Reading those in `NowPlayingView.body` made
/// the whole player re-evaluate on every playback tick; here only this trivial
/// view re-runs, forwarding the position into the scrub model so the scrub bar
/// stays live without dragging the rest of the player into the invalidation.
private struct PlaybackClock: View {
    let controller: AudioPlaybackController
    let model: MusicScrubModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: controller.currentTime, initial: true) { _, time in
                model.duration = controller.duration
                if !model.isScrubbing { model.currentSeconds = time }
            }
            .onChange(of: controller.duration) { _, duration in
                model.duration = duration
            }
    }
}

/// The right-hand lyrics column on the Now Playing screen. Renders the loading
/// state, the lyrics themselves (synced lyrics highlight + auto-scroll the active
/// line; plain lyrics just scroll), or a debug "No lyrics found" placeholder when
/// the track has none.
struct NowPlayingLyricsView: View {
    let state: AudioPlaybackController.LyricsState
    let currentTime: TimeInterval
    /// The lyrics source attribution is part of the optional "track details"
    /// surface, so it only shows when that setting is on. Passed in from the
    /// parent player (per-profile preference).
    let showTrackDetails: Bool
    /// Eases the lines in on first appearance instead of letting them pop.
    @State private var appeared = false
    /// Whether the spinner + "Searching for lyrics…" label should be visible
    /// for the current `.loading` window. Held off for `loadingChromeDelay` so
    /// resolves that finish quickly (cache hits, fast server hits) never flash
    /// the indicator on screen — the panel just stays blank for a beat and
    /// then snaps to the lyrics.
    @State private var showLoadingChrome = false
    private static let loadingChromeDelay: Duration = .milliseconds(500)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if showTrackDetails,
                   case let .loaded(lyrics) = state, let source = lyrics.source {
                    LyricsSourceBadge(source: source)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                }
            }
            // Reset the gate whenever we leave the loading state, and start the
            // delay countdown each time we enter it. `.task(id:)` cancels its
            // previous instance on identity change, which doubles as our timer
            // cancellation when the state moves to `.loaded`/`.unavailable`
            // before the delay elapses.
            .task(id: isLoadingState) {
                guard isLoadingState else {
                    showLoadingChrome = false
                    return
                }
                showLoadingChrome = false
                try? await Task.sleep(for: Self.loadingChromeDelay)
                guard !Task.isCancelled else { return }
                showLoadingChrome = true
            }
    }

    private var isLoadingState: Bool {
        switch state {
        case .idle, .loading: return true
        case .loaded, .unavailable, .silent: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading, .silent:
            // `.silent` is the "we already know there's nothing, stay quiet"
            // state — render exactly like `.idle` so the panel collapses
            // without ever flashing the spinner or the "No lyrics found"
            // message. The panel won't even be visible in this state thanks
            // to `updateLyricsPanelLatch`, but rendering as blank is the
            // belt-and-braces.
            VStack(spacing: 18) {
                Spacer()
                if showLoadingChrome {
                    ProgressView()
                    Text("Searching for lyrics…")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: showLoadingChrome)

        case .unavailable:
            VStack {
                Spacer()
                Text("No lyrics found")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(lyrics):
            lyricsScroll(lyrics)
        }
    }

    private func lyricsScroll(_ lyrics: Lyrics) -> some View {
        let active = activeIndex(in: lyrics)
        // The line to keep vertically centered. Before the first timestamp is
        // reached `active` is nil, so fall back to the upcoming line (line 0 at
        // the very start) — this guarantees the lyrics open centered rather than
        // pinned to the top.
        let focus = focusIndex(in: lyrics)
        let highlight = Animation.spring(response: 0.55, dampingFraction: 0.85)
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 52) {
                        // Top/bottom breathing room so the first and last lines
                        // can scroll all the way to the vertical center.
                        Color.clear.frame(height: geo.size.height * 0.45)
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 46, weight: .bold))
                                .foregroundStyle(.primary)
                                .opacity(opacity(forIndex: index, active: active))
                                .scaleEffect(index == active ? 1.06 : 1.0, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                .animation(highlight, value: active)
                        }
                        Color.clear.frame(height: geo.size.height * 0.45)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The active line scales up from its leading edge, so reserve
                    // a little room on the right; without it long lines render
                    // right up to the panel edge and the scaled-up current line
                    // gets clipped (and cut by the edge-fade mask).
                    .padding(.trailing, max(40, geo.size.width * 0.08))
                }
                .scrollDisabled(true)
                .mask(edgeFade)
                .opacity(appeared ? 1 : 0)
                .onChange(of: focus) { _, newIndex in
                    withAnimation(highlight) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                // Position correctly as soon as the panel appears and again once
                // the geometry settles (the panel animates in, so the first
                // onAppear can fire before the final height is known). The first
                // appearance also eases the lines in rather than popping.
                .onAppear {
                    proxy.scrollTo(focus, anchor: .center)
                    withAnimation(.easeOut(duration: 0.5)) { appeared = true }
                }
                .onChange(of: geo.size.height) { _, _ in
                    proxy.scrollTo(focus, anchor: .center)
                }
            }
        }
    }

    /// The line to keep centered: the active line, or — before the first
    /// timestamp is reached — the next upcoming line (line 0 at song start), so
    /// the lyrics always open in the middle.
    private func focusIndex(in lyrics: Lyrics) -> Int {
        if let active = activeIndex(in: lyrics) { return active }
        if lyrics.isSynced,
           let upcoming = lyrics.lines.firstIndex(where: { ($0.start ?? .infinity) > currentTime }) {
            return upcoming
        }
        return 0
    }

    /// Vertical edge fade. Lines stay fully visible through a wide central band
    /// and only dissolve in the outer ~16% at the top and bottom, so lyrics
    /// reach much closer to the panel edges before fading into the background.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.24),
                .init(color: .black, location: 0.76),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// How visible a line is given its distance from the active one: the current
    /// line is solid, neighbours dim progressively. With no active line (unsynced
    /// or pre-roll) every line sits at a calm, even brightness.
    private func opacity(forIndex index: Int, active: Int?) -> Double {
        guard let active else { return 0.25 }
        return index == active ? 1.0 : 0.25
    }

    /// A small anticipation lead (seconds) so a line highlights right as it's
    /// sung rather than a beat late. Compensates for residual sampling latency
    /// and matches how lyric apps nudge the active line slightly early.
    private static let lyricsLeadTime: TimeInterval = 0.3

    /// The index of the line currently being sung, for synced lyrics.
    private func activeIndex(in lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced else { return nil }
        let cue = currentTime + Self.lyricsLeadTime
        var match: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= cue { match = index } else { break }
        }
        return match
    }
}

/// Tiny attribution shown in the lyrics panel header: the source's brand mark
/// (the same app-bundle logos used in Settings for Jellyfin/Plex) plus its name.
/// LRCLIB has no bundled logo, so it uses an SF Symbol stand-in.
struct LyricsSourceBadge: View {
    let source: LyricsSource

    var body: some View {
        HStack(spacing: 6) {
            logo
            Text(source.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var logo: some View {
        switch source {
        case .jellyfin:
            Image("JellyfinLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
        case .plex:
            Image("PlexLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
        case .lrclib:
            Image(systemName: "quote.bubble").font(.caption)
        }
    }
}

private extension View {
    /// The system Liquid Glass button style (tvOS 26+), falling back to the
    /// bordered styles on older systems. `prominent` highlights play/active toggles.
    @ViewBuilder
    func musicGlassButton(prominent: Bool) -> some View {
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

/// Reports the natural height of the bottom control bar so the player can slide
/// it fully off the bottom edge as a single layer.
private struct BottomBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
