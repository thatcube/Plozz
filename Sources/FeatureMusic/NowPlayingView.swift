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
    @State private var scrubModel = MusicScrubModel()

    /// Whether the user wants the lyrics panel shown. Persisted (default on) so
    /// the choice is remembered across sessions. The toggle is disabled — and so
    /// can't be changed — when the current track has no lyrics.
    @AppStorage("musicLyricsEnabled") private var lyricsEnabled = true

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
            HStack(alignment: .center, spacing: 56) {
                playerColumn
                    .frame(maxWidth: showsLyricsPanel ? 760 : 960)
                if showsLyricsPanel {
                    NowPlayingLyricsView(
                        state: controller.lyricsState,
                        currentTime: controller.currentTime
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .animation(.easeInOut(duration: 0.25), value: showsLyricsPanel)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .padding(24)
            }
            .buttonStyle(.plain)
            .padding(32)
        }
        .onAppear {
            syncScrubModel()
            setIdleTimerDisabled(true)
        }
        .onDisappear { setIdleTimerDisabled(false) }
        .onChange(of: controller.currentTime) { _, _ in syncScrubModel() }
        .onChange(of: controller.duration) { _, _ in syncScrubModel() }
    }

    /// Keeps the Apple TV awake while the full-screen player is open so synced
    /// lyrics keep scrolling and artwork stays up during long, hands-off listens.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// The left-hand player column: artwork, track/artist/album, quality badge,
    /// scrub bar with play/pause, and the transport + lyrics-toggle row.
    private var playerColumn: some View {
        VStack(spacing: 36) {
            MusicArtworkImage(
                url: controller.currentTrack?.artworkURL,
                systemPlaceholder: "music.note",
                asyncFallbackURL: trackFallback(controller.currentTrack)
            )
                .frame(width: 420, height: 420)
                .shadow(radius: 30)

            VStack(spacing: 8) {
                Text(controller.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 46, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                if let subtitle = controller.currentTrack?.subtitle {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                qualityBadge
            }

            scrubRow
            transportRow
        }
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
        if let track = controller.currentTrack {
            FallbackAsyncImage(
                urls: [track.artworkURL].compactMap { $0 },
                asyncFallbackURL: MusicArtworkFallback.artistImage(name: track.artistName ?? "")
            ) {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color.black.ignoresSafeArea()
        }
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

    /// Play/pause beside a full-width analog scrub bar (+ elapsed/remaining times).
    private var scrubRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                prominent: true
            ) { controller.togglePlayPause() }

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
        }
    }

    /// Every other control, evenly sized, on the row below. Includes the lyrics
    /// toggle, which is disabled when the current track has no lyrics.
    private var transportRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: "shuffle",
                prominent: controller.isShuffled,
                tint: controller.isShuffled ? Color.accentColor : .primary
            ) { controller.toggleShuffle() }

            transportButton(icon: "backward.fill") { controller.previous() }
            transportButton(icon: "forward.fill") { controller.next() }

            transportButton(
                icon: repeatIcon,
                prominent: controller.repeatMode != .off,
                tint: controller.repeatMode == .off ? .primary : Color.accentColor
            ) { controller.cycleRepeatMode() }

            lyricsToggleButton
        }
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
        Button(action: action) {
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

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if case let .loaded(lyrics) = state, let source = lyrics.source {
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
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 52) {
                        // Top/bottom breathing room so the first and last lines
                        // can scroll all the way to the vertical center.
                        Color.clear.frame(height: geo.size.height * 0.45)
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(.primary)
                                .opacity(opacity(forIndex: index, active: active))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                .animation(.easeInOut(duration: 0.3), value: active)
                        }
                        Color.clear.frame(height: geo.size.height * 0.45)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(true)
                .mask(edgeFade)
                .onChange(of: focus) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                // Position correctly as soon as the panel appears and again once
                // the geometry settles (the panel animates in, so the first
                // onAppear can fire before the final height is known).
                .onAppear { proxy.scrollTo(focus, anchor: .center) }
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

    /// Vertical edge fade that makes lyrics fully dissolve **well before** the
    /// top and bottom edges: the outer ~quarter on each side is completely
    /// transparent, then it ramps up to solid only in a thin central band. Lines
    /// vanish into the background instead of reaching the panel edges.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.26),
                .init(color: .black, location: 0.46),
                .init(color: .black, location: 0.54),
                .init(color: .clear, location: 0.74),
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

    /// The index of the line currently being sung, for synced lyrics.
    private func activeIndex(in lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced else { return nil }
        var match: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= currentTime { match = index } else { break }
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
