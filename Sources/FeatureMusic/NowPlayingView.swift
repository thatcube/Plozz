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
    @AppStorage("musicLyricsEnabled") private var lyricsEnabled = true

    /// Whether the player shows extra track detail — album name, audio
    /// quality/format, and the lyrics source. Off by default to keep the screen
    /// clean (it's a niche audiophile detail); toggled from Settings ▸ Now
    /// Playing and remembered across sessions.
    @AppStorage("musicShowTrackDetails") private var showTrackDetails = false

    /// The lyrics panel is shown next to the player **only once lyrics are
    /// actually found**. While the background lookup is in flight (or if the track
    /// has none) the player stays centered full-width — we never give up half the
    /// screen for a spinner or an empty state. When lyrics arrive the player
    /// slides left to make room.
    private var showsLyricsPanel: Bool {
        lyricsEnabled && controller.lyricsState.hasLyrics
    }

    var body: some View {
        ZStack {
            background

            // Main content + bottom bar share a vertical stack so the artwork
            // and lyrics center in the space *above* the controls, then settle
            // down and re-center on the full screen once the bar slides away.
            VStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 80)
                    .padding(.top, 60)
                if controlsVisible {
                    bottomControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

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
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: controlsVisible)
        .onAppear {
            syncScrubModel()
            setIdleTimerDisabled(true)
            showControls()
        }
        .onDisappear {
            setIdleTimerDisabled(false)
            hideTask?.cancel()
        }
        .onChange(of: controller.currentTime) { _, _ in syncScrubModel() }
        .onChange(of: controller.duration) { _, _ in syncScrubModel() }
        .onChange(of: scrubModel.isScrubbing) { _, _ in scheduleHide() }
        // Any focus movement among the controls (or onto the scrub bar, which
        // clears `focus`) is a live interaction, so restart the idle countdown —
        // the bar only fades 5s after the *last* thing the user did.
        .onChange(of: focus) { _, _ in
            if controlsVisible { scheduleHide() }
        }
        .task(id: controller.currentTrack?.id) { await loadArtworkPalette() }
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
    }

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
                NowPlayingLyricsView(
                    state: controller.lyricsState,
                    currentTime: controller.currentTime
                )
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
                asyncFallbackURL: trackFallback(controller.currentTrack)
            )
                .frame(width: 420, height: 420)
                .shadow(radius: 30)

            VStack(spacing: 10) {
                Text(controller.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 46, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                if let artist = controller.currentTrack?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                if showTrackDetails {
                    if let album = controller.currentTrack?.albumTitle, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                    }
                    qualityBadge
                }
            }
        }
    }

    /// The full-width transport bar across the bottom: scrub row + button row,
    /// over a soft dark scrim so it stays legible against the artwork colors.
    private var bottomControls: some View {
        VStack(spacing: 24) {
            scrubRow
            transportRow
        }
        .padding(.horizontal, 80)
        .padding(.top, 48)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
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
        LiquidArtworkBackground(palette: artworkPalette, animate: !reduceMotion)
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
            .padding(.top, 4)
        }
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
            MusicScrubBar(model: scrubModel)
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

    /// The transport row: the big round play/pause sits dead-centre with
    /// previous/next flanking it, shuffle pinned left and repeat + lyrics pinned
    /// right. Every button carries a Focus case so moving between them keeps the
    /// bar awake.
    private var transportRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: "shuffle",
                prominent: controller.isShuffled,
                tint: controller.isShuffled ? Color.accentColor : .primary
            ) { controller.toggleShuffle() }
                .focused($focus, equals: .shuffle)

            Spacer(minLength: 24)

            transportButton(icon: "backward.fill") { controller.previous() }
                .focused($focus, equals: .previous)

            playPauseButton

            transportButton(icon: "forward.fill") { controller.next() }
                .focused($focus, equals: .next)

            Spacer(minLength: 24)

            transportButton(
                icon: repeatIcon,
                prominent: controller.repeatMode != .off,
                tint: controller.repeatMode == .off ? .primary : Color.accentColor
            ) { controller.cycleRepeatMode() }
                .focused($focus, equals: .repeatMode)

            lyricsToggleButton
                .focused($focus, equals: .lyrics)
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
            prominent: lyricsEnabled && hasLyrics,
            tint: (lyricsEnabled && hasLyrics) ? Color.accentColor : .primary
        ) {
            lyricsEnabled.toggle()
        }
        .disabled(!hasLyrics)
        .opacity(hasLyrics ? 1 : 0.4)
    }

    private func transportButton(
        icon: String,
        prominent: Bool = false,
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
        .musicGlassButton(prominent: prominent)
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

/// The right-hand lyrics column on the Now Playing screen. Renders the loading
/// state, the lyrics themselves (synced lyrics highlight + auto-scroll the active
/// line; plain lyrics just scroll), or a debug "No lyrics found" placeholder when
/// the track has none.
struct NowPlayingLyricsView: View {
    let state: AudioPlaybackController.LyricsState
    let currentTime: TimeInterval
    /// Eases the lines in on first appearance instead of letting them pop.
    @State private var appeared = false
    /// The lyrics source attribution is part of the optional "track details"
    /// surface, so it only shows when that setting is on.
    @AppStorage("musicShowTrackDetails") private var showTrackDetails = false

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
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
#endif
